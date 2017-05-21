# cython: infer_types=True
# cython: profile=True
# coding: utf8
from __future__ import unicode_literals

from thinc.api import chain, layerize, with_getitem
from thinc.neural import Model, Softmax
import numpy
cimport numpy as np
import cytoolz
import util

from thinc.api import add, layerize, chain, clone, concatenate, with_flatten
from thinc.neural import Model, Maxout, Softmax, Affine
from thinc.neural._classes.hash_embed import HashEmbed
from thinc.neural.util import to_categorical

from thinc.neural._classes.convolution import ExtractWindow
from thinc.neural._classes.resnet import Residual
from thinc.neural._classes.batchnorm import BatchNorm as BN

from .tokens.doc cimport Doc
from .syntax.parser cimport Parser as LinearParser
from .syntax.nn_parser cimport Parser as NeuralParser
from .syntax.parser import get_templates as get_feature_templates
from .syntax.beam_parser cimport BeamParser
from .syntax.ner cimport BiluoPushDown
from .syntax.arc_eager cimport ArcEager
from .tagger import Tagger
from .syntax.stateclass cimport StateClass
from .gold cimport GoldParse
from .morphology cimport Morphology
from .vocab cimport Vocab

from .attrs import ID, LOWER, PREFIX, SUFFIX, SHAPE, TAG, DEP, POS
from ._ml import rebatch, Tok2Vec, flatten, get_col, doc2feats
from .parts_of_speech import X


class TokenVectorEncoder(object):
    '''Assign position-sensitive vectors to tokens, using a CNN or RNN.'''
    name = 'tok2vec'

    @classmethod
    def Model(cls, width=128, embed_size=5000, **cfg):
        width = util.env_opt('token_vector_width', width)
        embed_size = util.env_opt('embed_size', embed_size)
        return Tok2Vec(width, embed_size, preprocess=None)

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.doc2feats = doc2feats()
        self.model = model

    def __call__(self, docs):
        if isinstance(docs, Doc):
            docs = [docs]
        tokvecses = self.predict(docs)
        self.set_annotations(docs, tokvecses)

    def pipe(self, stream, batch_size=128, n_threads=-1):
        for docs in cytoolz.partition_all(batch_size, stream):
            tokvecses = self.predict(docs)
            self.set_annotations(docs, tokvecses)
            yield from docs

    def predict(self, docs):
        feats = self.doc2feats(docs)
        tokvecs = self.model(feats)
        return tokvecs

    def set_annotations(self, docs, tokvecses):
        for doc, tokvecs in zip(docs, tokvecses):
            doc.tensor = tokvecs

    def begin_update(self, docs, drop=0.):
        if isinstance(docs, Doc):
            docs = [docs]
        feats = self.doc2feats(docs)
        tokvecs, bp_tokvecs = self.model.begin_update(feats, drop=drop)
        return tokvecs, bp_tokvecs

    def get_loss(self, docs, golds, scores):
        raise NotImplementedError

    def begin_training(self, gold_tuples, pipeline=None):
        self.doc2feats = doc2feats()
        if self.model is True:
            self.model = self.Model()

    def use_params(self, params):
        with self.model.use_params(params):
            yield


class NeuralTagger(object):
    name = 'nn_tagger'
    def __init__(self, vocab, model=True):
        self.vocab = vocab
        self.model = model

    def __call__(self, doc):
        tags = self.predict(doc.tensor)
        self.set_annotations([doc], tags)

    def pipe(self, stream, batch_size=128, n_threads=-1):
        for docs in cytoolz.partition_all(batch_size, stream):
            tokvecs = [d.tensor for d in docs]
            tag_ids = self.predict(tokvecs)
            self.set_annotations(docs, tag_ids)
            yield from docs

    def predict(self, tokvecs):
        scores = self.model(tokvecs)
        scores = self.model.ops.flatten(scores)
        guesses = scores.argmax(axis=1)
        if not isinstance(guesses, numpy.ndarray):
            guesses = guesses.get()
        guesses = self.model.ops.unflatten(guesses,
                    [tv.shape[0] for tv in tokvecs])
        return guesses

    def set_annotations(self, docs, batch_tag_ids):
        if isinstance(docs, Doc):
            docs = [docs]
        cdef Doc doc
        cdef int idx = 0
        cdef Vocab vocab = self.vocab
        for i, doc in enumerate(docs):
            doc_tag_ids = batch_tag_ids[i]
            for j, tag_id in enumerate(doc_tag_ids):
                vocab.morphology.assign_tag_id(&doc.c[j], tag_id)
                idx += 1

    def update(self, docs_tokvecs, golds, drop=0., sgd=None):
        docs, tokvecs = docs_tokvecs

        if self.model.nI is None:
            self.model.nI = tokvecs[0].shape[1]

        tag_scores, bp_tag_scores = self.model.begin_update(tokvecs, drop=drop)
        loss, d_tag_scores = self.get_loss(docs, golds, tag_scores)

        d_tokvecs = bp_tag_scores(d_tag_scores, sgd=sgd)

        return d_tokvecs

    def get_loss(self, docs, golds, scores):
        scores = self.model.ops.flatten(scores)
        tag_index = {tag: i for i, tag in enumerate(self.vocab.morphology.tag_names)}

        cdef int idx = 0
        correct = numpy.zeros((scores.shape[0],), dtype='i')
        guesses = scores.argmax(axis=1)
        for gold in golds:
            for tag in gold.tags:
                if tag is None:
                    correct[idx] = guesses[idx]
                else:
                    correct[idx] = tag_index[tag]
                idx += 1
        correct = self.model.ops.xp.array(correct, dtype='i')
        d_scores = scores - to_categorical(correct, nb_classes=scores.shape[1])
        loss = (d_scores**2).sum()
        d_scores = self.model.ops.unflatten(d_scores, [len(d) for d in docs])
        return float(loss), d_scores

    def begin_training(self, gold_tuples, pipeline=None):
        orig_tag_map = dict(self.vocab.morphology.tag_map)
        new_tag_map = {}
        for raw_text, annots_brackets in gold_tuples:
            for annots, brackets in annots_brackets:
                ids, words, tags, heads, deps, ents = annots
                for tag in tags:
                    if tag in orig_tag_map:
                        new_tag_map[tag] = orig_tag_map[tag]
                    else:
                        new_tag_map[tag] = {POS: X}
        cdef Vocab vocab = self.vocab
        vocab.morphology = Morphology(vocab.strings, new_tag_map,
                                      vocab.morphology.lemmatizer)
        token_vector_width = pipeline[0].model.nO
        self.model = with_flatten(
            Softmax(self.vocab.morphology.n_tags, token_vector_width))

    def use_params(self, params):
        with self.model.use_params(params):
            yield


cdef class EntityRecognizer(LinearParser):
    """
    Annotate named entities on Doc objects.
    """
    TransitionSystem = BiluoPushDown

    feature_templates = get_feature_templates('ner')

    def add_label(self, label):
        LinearParser.add_label(self, label)
        if isinstance(label, basestring):
            label = self.vocab.strings[label]


cdef class BeamEntityRecognizer(BeamParser):
    """
    Annotate named entities on Doc objects.
    """
    TransitionSystem = BiluoPushDown

    feature_templates = get_feature_templates('ner')

    def add_label(self, label):
        LinearParser.add_label(self, label)
        if isinstance(label, basestring):
            label = self.vocab.strings[label]


cdef class DependencyParser(LinearParser):
    TransitionSystem = ArcEager
    feature_templates = get_feature_templates('basic')

    def add_label(self, label):
        LinearParser.add_label(self, label)
        if isinstance(label, basestring):
            label = self.vocab.strings[label]


cdef class NeuralDependencyParser(NeuralParser):
    name = 'parser'
    TransitionSystem = ArcEager


cdef class NeuralEntityRecognizer(NeuralParser):
    name = 'entity'
    TransitionSystem = BiluoPushDown

    nr_feature = 6

    def get_token_ids(self, states):
        cdef StateClass state
        cdef int n_tokens = 6
        ids = numpy.zeros((len(states), n_tokens), dtype='i', order='c')
        for i, state in enumerate(states):
            ids[i, 0] = state.c.B(0)-1
            ids[i, 1] = state.c.B(0)
            ids[i, 2] = state.c.B(1)
            ids[i, 3] = state.c.E(0)
            ids[i, 4] = state.c.E(0)-1
            ids[i, 5] = state.c.E(0)+1
            for j in range(6):
                if ids[i, j] >= state.c.length:
                    ids[i, j] = -1
                if ids[i, j] != -1:
                    ids[i, j] += state.c.offset
        return ids


cdef class BeamDependencyParser(BeamParser):
    TransitionSystem = ArcEager

    feature_templates = get_feature_templates('basic')

    def add_label(self, label):
        Parser.add_label(self, label)
        if isinstance(label, basestring):
            label = self.vocab.strings[label]


__all__ = ['Tagger', 'DependencyParser', 'EntityRecognizer', 'BeamDependencyParser',
           'BeamEntityRecognizer', 'TokenVectorEnoder']
