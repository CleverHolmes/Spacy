# coding: utf8
from __future__ import unicode_literals
from thinc.neural import Model
import pytest
import numpy

from ..._ml import chain, Tok2Vec, doc2feats
from ...vocab import Vocab
from ...pipeline import TokenVectorEncoder
from ...syntax.arc_eager import ArcEager
from ...syntax.nn_parser import Parser
from ...tokens.doc import Doc
from ...gold import GoldParse


@pytest.fixture
def vocab():
    return Vocab()


@pytest.fixture
def arc_eager(vocab):
    actions = ArcEager.get_actions(left_labels=['L'], right_labels=['R'])
    return ArcEager(vocab.strings, actions)


@pytest.fixture
def tok2vec():
    return Tok2Vec(8, 100, preprocess=doc2feats())


@pytest.fixture
def parser(vocab, arc_eager):
    return Parser(vocab, moves=arc_eager, model=None)

@pytest.fixture
def model(arc_eager, tok2vec):
    return Parser.Model(arc_eager.n_moves, token_vector_width=tok2vec.nO)[0]

@pytest.fixture
def doc(vocab):
    return Doc(vocab, words=['a', 'b', 'c'])

@pytest.fixture
def gold(doc):
    return GoldParse(doc, heads=[1, 1, 1], deps=['L', 'ROOT', 'R'])


def test_can_init_nn_parser(parser):
    assert parser.model is None


def test_build_model(parser):
    parser.model = Parser.Model(parser.moves.n_moves)[0]
    assert parser.model is not None


def test_predict_doc(parser, tok2vec, model, doc):
    doc.tensor = tok2vec([doc])[0]
    parser.model = model
    parser(doc)


def test_update_doc(parser, tok2vec, model, doc, gold):
    parser.model = model
    tokvecs, bp_tokvecs = tok2vec.begin_update([doc])
    d_tokvecs = parser.update(([doc], tokvecs), [gold])
    assert d_tokvecs[0].shape == tokvecs[0].shape
    def optimize(weights, gradient, key=None):
        weights -= 0.001 * gradient
    bp_tokvecs(d_tokvecs, sgd=optimize)
    assert d_tokvecs[0].sum() == 0.


def test_predict_doc_beam(parser, tok2vec, model, doc):
    doc.tensor = tok2vec([doc])[0]
    parser.model = model
    parser(doc, beam_width=32, beam_density=0.001)
    for word in doc:
        print(word.text, word.head, word.dep_)
