# coding: utf8
from __future__ import unicode_literals, division, print_function

import json
from collections import defaultdict
import cytoolz
from pathlib import Path
import dill

from ..tokens.doc import Doc
from ..scorer import Scorer
from ..gold import GoldParse, merge_sents
from ..gold import read_json_file as read_gold_json
from ..util import prints
from .. import util
from .. import displacy


def train(language, output_dir, train_data, dev_data, n_iter, n_sents,
          use_gpu, tagger, parser, ner, parser_L1):
    output_path = util.ensure_path(output_dir)
    train_path = util.ensure_path(train_data)
    dev_path = util.ensure_path(dev_data)
    if not output_path.exists():
        prints(output_path, title="Output directory not found", exits=True)
    if not train_path.exists():
        prints(train_path, title="Training data not found", exits=True)
    if dev_path and not dev_path.exists():
        prints(dev_path, title="Development data not found", exits=True)

    lang = util.get_lang_class(language)
    parser_cfg = {
        'pseudoprojective': True,
        'L1': parser_L1,
        'n_iter': n_iter,
        'lang': language,
        'features': lang.Defaults.parser_features}
    entity_cfg = {
        'n_iter': n_iter,
        'lang': language,
        'features': lang.Defaults.entity_features}
    tagger_cfg = {
        'n_iter': n_iter,
        'lang': language,
        'features': lang.Defaults.tagger_features}
    gold_train = list(read_gold_json(train_path, limit=n_sents))
    gold_dev = list(read_gold_json(dev_path, limit=n_sents)) if dev_path else None

    train_model(lang, gold_train, gold_dev, output_path, n_iter, use_gpu=use_gpu)
    if gold_dev:
        scorer = evaluate(lang, gold_dev, output_path)
        print_results(scorer)


def train_config(config):
    config_path = util.ensure_path(config)
    if not config_path.is_file():
        prints(config_path, title="Config file not found", exits=True)
    config = json.load(config_path)
    for setting in []:
        if setting not in config.keys():
            prints("%s not found in config file." % setting, title="Missing setting")


def train_model(Language, train_data, dev_data, output_path, n_iter, **cfg):
    print("Itn.\tDep. Loss\tUAS\tNER F.\tTag %\tToken %")

    nlp = Language(pipeline=['token_vectors', 'tags', 'dependencies'])
    dropout = util.env_opt('dropout', 0.0)
    # TODO: Get spaCy using Thinc's trainer and optimizer
    with nlp.begin_training(train_data, **cfg) as (trainer, optimizer):
        for itn, epoch in enumerate(trainer.epochs(n_iter, gold_preproc=True)):
            losses = defaultdict(float)
            to_render = []
            for i, (docs, golds) in enumerate(epoch):
                state = nlp.update(docs, golds, drop=dropout, sgd=optimizer)
                losses['dep_loss'] += state.get('parser_loss', 0.0)
                losses['tag_loss'] += state.get('tag_loss', 0.0)
                to_render.insert(0, nlp(docs[-1].text))
                to_render[0].user_data['title'] = "Batch %d" % i
                with Path('/tmp/entities.html').open('w') as file_:
                    html = displacy.render(to_render[:5], style='ent', page=True)
                    file_.write(html)
                with Path('/tmp/parses.html').open('w') as file_:
                    html = displacy.render(to_render[:5], style='dep', page=True)
                    file_.write(html)
            if dev_data:
                with nlp.use_params(optimizer.averages):
                    dev_scores = trainer.evaluate(dev_data).scores
            else:
                dev_scores = defaultdict(float)
            print_progress(itn, losses, dev_scores)
    with (output_path / 'model.bin').open('wb') as file_:
        dill.dump(nlp, file_, -1)
    #nlp.to_disk(output_path, tokenizer=False)


def evaluate(Language, gold_tuples, path):
    with (path / 'model.bin').open('rb') as file_:
        nlp = dill.load(file_)
    # TODO:
    # 1. This code is duplicate with spacy.train.Trainer.evaluate
    # 2. There's currently a semantic difference between pipe and
    #    not pipe! It matters whether we batch the inputs. Must fix!
    all_docs = []
    all_golds = []
    for raw_text, paragraph_tuples in dev_sents:
        if gold_preproc:
            raw_text = None
        else:
            paragraph_tuples = merge_sents(paragraph_tuples)
        docs = self.make_docs(raw_text, paragraph_tuples)
        golds = self.make_golds(docs, paragraph_tuples)
        all_docs.extend(docs)
        all_golds.extend(golds)
    scorer = Scorer()
    for doc, gold in zip(self.nlp.pipe(all_docs), all_golds):
        scorer.score(doc, gold)
    return scorer


def print_progress(itn, losses, dev_scores):
    # TODO: Fix!
    scores = {}
    for col in ['dep_loss', 'tag_loss', 'uas', 'tags_acc', 'token_acc', 'ents_f']:
        scores[col] = 0.0
    scores.update(losses)
    scores.update(dev_scores)
    tpl = '{:d}\t{dep_loss:.3f}\t{tag_loss:.3f}\t{uas:.3f}\t{ents_f:.3f}\t{tags_acc:.3f}\t{token_acc:.3f}'
    print(tpl.format(itn, **scores))


def print_results(scorer):
    results = {
        'TOK': '%.2f' % scorer.token_acc,
        'POS': '%.2f' % scorer.tags_acc,
        'UAS': '%.2f' % scorer.uas,
        'LAS': '%.2f' % scorer.las,
        'NER P': '%.2f' % scorer.ents_p,
        'NER R': '%.2f' % scorer.ents_r,
        'NER F': '%.2f' % scorer.ents_f}
    util.print_table(results, title="Results")
