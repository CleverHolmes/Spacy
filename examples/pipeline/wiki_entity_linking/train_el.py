# coding: utf-8
from __future__ import unicode_literals

import os
import datetime
from os import listdir
import numpy as np
import random
from thinc.neural._classes.convolution import ExtractWindow

from examples.pipeline.wiki_entity_linking import run_el, training_set_creator, kb_creator

from spacy._ml import SpacyVectors, create_default_optimizer, zero_init, logistic

from thinc.api import chain, concatenate, flatten_add_lengths, clone, with_flatten
from thinc.v2v import Model, Maxout, Affine, ReLu
from thinc.t2v import Pooling, mean_pool, sum_pool
from thinc.t2t import ParametricAttention
from thinc.misc import Residual
from thinc.misc import LayerNorm as LN

from spacy.tokens import Doc

""" TODO: this code needs to be implemented in pipes.pyx"""


class EL_Model:

    PRINT_LOSS = False
    PRINT_F = True
    PRINT_TRAIN = False
    EPS = 0.0000000005
    CUTOFF = 0.5

    INPUT_DIM = 300
    HIDDEN_1_WIDTH = 256  # 10
    HIDDEN_2_WIDTH = 32  # 6
    ENTITY_WIDTH = 64     # 4
    ARTICLE_WIDTH = 128   # 8

    DROP = 0.1

    name = "entity_linker"

    def __init__(self, kb, nlp):
        run_el._prepare_pipeline(nlp, kb)
        self.nlp = nlp
        self.kb = kb

        self._build_cnn(in_width=self.INPUT_DIM,
                        entity_width=self.ENTITY_WIDTH,
                        article_width=self.ARTICLE_WIDTH,
                        hidden_1_width=self.HIDDEN_1_WIDTH,
                        hidden_2_width=self.HIDDEN_2_WIDTH)

    def train_model(self, training_dir, entity_descr_output, trainlimit=None, devlimit=None, to_print=True):
        # raise errors instead of runtime warnings in case of int/float overflow
        np.seterr(all='raise')

        train_inst, train_pos, train_neg, train_texts = self._get_training_data(training_dir,
                                                                                entity_descr_output,
                                                                                False,
                                                                                trainlimit,
                                                                                balance=True,
                                                                                to_print=False)

        dev_inst, dev_pos, dev_neg, dev_texts = self._get_training_data(training_dir,
                                                                        entity_descr_output,
                                                                        True,
                                                                        devlimit,
                                                                        balance=False,
                                                                        to_print=False)
        self._begin_training()

        print()
        self._test_dev(dev_inst, dev_pos, dev_neg, dev_texts, print_string="dev_random", calc_random=True)
        self._test_dev(dev_inst, dev_pos, dev_neg, dev_texts, print_string="dev_pre", avg=False)

        instance_pos_count = 0
        instance_neg_count = 0

        if to_print:
            print()
            print("Training on", len(train_inst.values()), "articles")
            print("Dev test on", len(dev_inst.values()), "articles")
            print()
            print(" CUTOFF", self.CUTOFF)
            print(" INPUT_DIM", self.INPUT_DIM)
            print(" HIDDEN_1_WIDTH", self.HIDDEN_1_WIDTH)
            print(" ENTITY_WIDTH", self.ENTITY_WIDTH)
            print(" ARTICLE_WIDTH", self.ARTICLE_WIDTH)
            print(" HIDDEN_2_WIDTH", self.HIDDEN_2_WIDTH)
            print(" DROP", self.DROP)
            print()

        # TODO: proper batches. Currently 1 article at the time
        # TODO shuffle data (currently positive is always followed by several negatives)
        article_count = 0
        for article_id, inst_cluster_set in train_inst.items():
            try:
                # if to_print:
                    # print()
                    # print(article_count, "Training on article", article_id)
                article_count += 1
                article_text = train_texts[article_id]
                entities = list()
                golds = list()
                for inst_cluster in inst_cluster_set:
                    entities.append(train_pos.get(inst_cluster))
                    golds.append(float(1.0))
                    instance_pos_count += 1
                    for neg_entity in train_neg.get(inst_cluster, []):
                        entities.append(neg_entity)
                        golds.append(float(0.0))
                        instance_neg_count += 1

                self.update(article_text=article_text, entities=entities, golds=golds)

                # dev eval
                self._test_dev(dev_inst, dev_pos, dev_neg, dev_texts, print_string="dev_inter_avg", avg=True)
            except ValueError as e:
                print("Error in article id", article_id)

        if to_print:
            print()
            print("Trained on", instance_pos_count, "/", instance_neg_count, "instances pos/neg")

    def _test_dev(self, instances, pos, neg, texts_by_id, print_string, avg=False, calc_random=False):
        predictions = list()
        golds = list()

        for article_id, inst_cluster_set in instances.items():
            for inst_cluster in inst_cluster_set:
                pos_ex = pos.get(inst_cluster)
                neg_exs = neg.get(inst_cluster, [])

                article = inst_cluster.split(sep="_")[0]
                entity_id = inst_cluster.split(sep="_")[1]
                article_doc = self.nlp(texts_by_id[article])
                entities = [self.nlp(pos_ex)]
                golds.append(float(1.0))
                for neg_ex in neg_exs:
                    entities.append(self.nlp(neg_ex))
                    golds.append(float(0.0))

                if calc_random:
                    preds = self._predict_random(entities=entities)
                else:
                    preds = self._predict(article_doc=article_doc, entities=entities, avg=avg)
                predictions.extend(preds)

        # TODO: combine with prior probability
        p, r, f = run_el.evaluate(predictions, golds, to_print=False)
        if self.PRINT_F:
            print("p/r/F", print_string, round(p, 1), round(r, 1), round(f, 1))

        loss, gradient = self.get_loss(self.model.ops.asarray(predictions), self.model.ops.asarray(golds))
        if self.PRINT_LOSS:
            print("loss", print_string, round(loss, 5))

        return loss, p, r, f

    def _predict(self, article_doc, entities, avg=False, apply_threshold=True):
        if avg:
            with self.article_encoder.use_params(self.sgd_article.averages) \
                 and self.entity_encoder.use_params(self.sgd_entity.averages):
                doc_encoding = self.article_encoder([article_doc])[0]
                entity_encodings = self.entity_encoder(entities)

        else:
            doc_encoding = self.article_encoder([article_doc])[0]
            entity_encodings = self.entity_encoder(entities)

        concat_encodings = [list(entity_encodings[i]) + list(doc_encoding) for i in range(len(entities))]
        np_array_list = np.asarray(concat_encodings)

        if avg:
            with self.model.use_params(self.sgd.averages):
                predictions = self.model(np_array_list)
        else:
            predictions = self.model(np_array_list)

        predictions = self.model.ops.flatten(predictions)
        predictions = [float(p) for p in predictions]
        if apply_threshold:
            predictions = [float(1.0) if p > self.CUTOFF else float(0.0) for p in predictions]

        return predictions

    def _predict_random(self, entities, apply_threshold=True):
        if not apply_threshold:
            return [float(random.uniform(0,1)) for e in entities]
        else:
            return [float(1.0) if random.uniform(0,1) > self.CUTOFF else float(0.0) for e in entities]

    def _build_cnn(self, in_width, entity_width, article_width, hidden_1_width, hidden_2_width):
        with Model.define_operators({">>": chain, "|": concatenate, "**": clone}):
            self.entity_encoder = self._encoder(in_width=in_width, hidden_with=hidden_1_width, end_width=entity_width)
            self.article_encoder = self._encoder(in_width=in_width, hidden_with=hidden_1_width, end_width=article_width)

            in_width = entity_width + article_width
            out_width = hidden_2_width

            self.model = Affine(out_width, in_width) \
                >> LN(Maxout(out_width, out_width)) \
                >> Affine(1, out_width) \
                >> logistic

    @staticmethod
    def _encoder(in_width, hidden_with, end_width):
        conv_depth = 2
        cnn_maxout_pieces = 3

        with Model.define_operators({">>": chain}):
            convolution = Residual((ExtractWindow(nW=1) >> LN(Maxout(hidden_with, hidden_with * 3, pieces=cnn_maxout_pieces))))

            encoder = SpacyVectors \
                      >> with_flatten(LN(Maxout(hidden_with, in_width)) >> convolution ** conv_depth, pad=conv_depth) \
                      >> flatten_add_lengths \
                      >> ParametricAttention(hidden_with)\
                      >> Pooling(mean_pool) \
                      >> Residual(zero_init(Maxout(hidden_with, hidden_with))) \
                      >> zero_init(Affine(end_width, hidden_with, drop_factor=0.0))

            # TODO: ReLu or LN(Maxout)  ?
            # sum_pool or mean_pool ?

        return encoder

    def _begin_training(self):
        self.sgd_article = create_default_optimizer(self.article_encoder.ops)
        self.sgd_entity = create_default_optimizer(self.entity_encoder.ops)
        self.sgd = create_default_optimizer(self.model.ops)

    @staticmethod
    def get_loss(predictions, golds):
        d_scores = (predictions - golds)
        loss = (d_scores ** 2).mean()
        return loss, d_scores

    # TODO: multiple docs/articles
    def update(self, article_text, entities, golds, apply_threshold=True):
        article_doc = self.nlp(article_text)
        # entity_docs = list(self.nlp.pipe(entities))

        for entity, gold in zip(entities, golds):
            doc_encodings, bp_doc = self.article_encoder.begin_update([article_doc], drop=self.DROP)
            doc_encoding = doc_encodings[0]

            entity_doc = self.nlp(entity)
            # print("entity_docs", type(entity_doc))

            entity_encodings, bp_entity = self.entity_encoder.begin_update([entity_doc], drop=self.DROP)
            entity_encoding = entity_encodings[0]
            # print("entity_encoding", len(entity_encoding), entity_encoding)

            concat_encodings = [list(entity_encoding) + list(doc_encoding)]  #  for i in range(len(entities))
            # print("concat_encodings", len(concat_encodings), concat_encodings)

            prediction, bp_model = self.model.begin_update(np.asarray(concat_encodings), drop=self.DROP)
            # predictions = self.model.ops.flatten(predictions)

            # print("prediction", prediction)
            # golds = self.model.ops.asarray(golds)
            # print("gold", gold)

            loss, gradient = self.get_loss(prediction, gold)

            if self.PRINT_LOSS and self.PRINT_TRAIN:
                print("loss train", round(loss, 5))

            gradient = float(gradient)
            # print("gradient", gradient)
            # print("loss", loss)

            model_gradient = bp_model(gradient, sgd=self.sgd)
            # print("model_gradient", model_gradient)

            # concat = entity + doc, but doc is the same within this function (TODO: multiple docs/articles)
            doc_gradient = model_gradient[0][self.ENTITY_WIDTH:]
            entity_gradients = list()
            for x in model_gradient:
                entity_gradients.append(list(x[0:self.ENTITY_WIDTH]))

            # print("doc_gradient", doc_gradient)
            # print("entity_gradients", entity_gradients)

            bp_doc([doc_gradient], sgd=self.sgd_article)
            bp_entity(entity_gradients, sgd=self.sgd_entity)

    def _get_training_data(self, training_dir, entity_descr_output, dev, limit, balance, to_print):
        id_to_descr = kb_creator._get_id_to_description(entity_descr_output)

        correct_entries, incorrect_entries = training_set_creator.read_training_entities(training_output=training_dir,
                                                                                         collect_correct=True,
                                                                                         collect_incorrect=True)

        instance_by_article = dict()
        local_vectors = list()   # TODO: local vectors
        text_by_article = dict()
        pos_entities = dict()
        neg_entities = dict()

        cnt = 0
        for f in listdir(training_dir):
            if not limit or cnt < limit:
                if dev == run_el.is_dev(f):
                    article_id = f.replace(".txt", "")
                    if cnt % 500 == 0 and to_print:
                        print(datetime.datetime.now(), "processed", cnt, "files in the training dataset")
                    cnt += 1
                    if article_id not in text_by_article:
                        with open(os.path.join(training_dir, f), mode="r", encoding='utf8') as file:
                            text = file.read()
                            text_by_article[article_id] = text
                            instance_by_article[article_id] = set()

                    for mention, entity_pos in correct_entries[article_id].items():
                        descr = id_to_descr.get(entity_pos)
                        if descr:
                            instance_by_article[article_id].add(article_id + "_" + mention)
                            pos_entities[article_id + "_" + mention] = descr

                    for mention, entity_negs in incorrect_entries[article_id].items():
                        if not balance or pos_entities.get(article_id + "_" + mention):
                            neg_count = 0
                            for entity_neg in entity_negs:
                                # if balance, keep only 1 negative instance for each positive instance
                                if neg_count < 1 or not balance:
                                    descr = id_to_descr.get(entity_neg)
                                    if descr:
                                        descr_list = neg_entities.get(article_id + "_" + mention, [])
                                        descr_list.append(descr)
                                        neg_entities[article_id + "_" + mention] = descr_list
                                        neg_count += 1

        if to_print:
            print()
            print("Processed", cnt, "training articles, dev=" + str(dev))
            print()
        return instance_by_article, pos_entities, neg_entities, text_by_article
