# coding: utf-8
from __future__ import unicode_literals

import pytest
from spacy.pipeline import Tagger, DependencyParser, EntityRecognizer, Tensorizer, TextCategorizer

from ..util import make_tempdir


test_parsers = [DependencyParser, EntityRecognizer]


@pytest.fixture
def parser(en_vocab):
    parser = DependencyParser(en_vocab)
    parser.add_label('nsubj')
    parser.model, cfg = parser.Model(parser.moves.n_moves)
    parser.cfg.update(cfg)
    return parser


@pytest.fixture
def blank_parser(en_vocab):
    parser = DependencyParser(en_vocab)
    return parser


@pytest.fixture
def taggers(en_vocab):
    tagger1 = Tagger(en_vocab)
    tagger2 = Tagger(en_vocab)
    tagger1.model = tagger1.Model(8)
    tagger2.model = tagger1.model
    return (tagger1, tagger2)


@pytest.mark.parametrize('Parser', test_parsers)
def test_serialize_parser_roundtrip_bytes(en_vocab, Parser):
    parser = Parser(en_vocab)
    parser.model, _ = parser.Model(10)
    new_parser = Parser(en_vocab)
    new_parser.model, _ = new_parser.Model(10)
    new_parser = new_parser.from_bytes(parser.to_bytes())
    assert new_parser.to_bytes() == parser.to_bytes()


@pytest.mark.parametrize('Parser', test_parsers)
def test_serialize_parser_roundtrip_disk(en_vocab, Parser):
    parser = Parser(en_vocab)
    parser.model, _ = parser.Model(0)
    with make_tempdir() as d:
        file_path = d / 'parser'
        parser.to_disk(file_path)
        parser_d = Parser(en_vocab)
        parser_d.model, _ = parser_d.Model(0)
        parser_d = parser_d.from_disk(file_path)
        assert parser.to_bytes(model=False) == parser_d.to_bytes(model=False)


def test_to_from_bytes(parser, blank_parser):
    assert parser.model is not True
    assert blank_parser.model is True
    assert blank_parser.moves.n_moves != parser.moves.n_moves
    bytes_data = parser.to_bytes()
    blank_parser.from_bytes(bytes_data)
    assert blank_parser.model is not True
    assert blank_parser.moves.n_moves == parser.moves.n_moves


@pytest.mark.skip(reason="This seems to be a dict ordering bug somewhere. Only failing on some platforms.")
def test_serialize_tagger_roundtrip_bytes(en_vocab, taggers):
    tagger1, tagger2 = taggers
    tagger1_b = tagger1.to_bytes()
    tagger2_b = tagger2.to_bytes()
    tagger1 = tagger1.from_bytes(tagger1_b)
    assert tagger1.to_bytes() == tagger1_b
    new_tagger1 = Tagger(en_vocab).from_bytes(tagger1_b)
    assert new_tagger1.to_bytes() == tagger1_b


def test_serialize_tagger_roundtrip_disk(en_vocab, taggers):
    tagger1, tagger2 = taggers
    with make_tempdir() as d:
        file_path1 = d / 'tagger1'
        file_path2 = d / 'tagger2'
        tagger1.to_disk(file_path1)
        tagger2.to_disk(file_path2)
        tagger1_d = Tagger(en_vocab).from_disk(file_path1)
        tagger2_d = Tagger(en_vocab).from_disk(file_path2)
        assert tagger1_d.to_bytes() == tagger2_d.to_bytes()


def test_serialize_tensorizer_roundtrip_bytes(en_vocab):
    tensorizer = Tensorizer(en_vocab)
    tensorizer.model = tensorizer.Model()
    tensorizer_b = tensorizer.to_bytes()
    new_tensorizer = Tensorizer(en_vocab).from_bytes(tensorizer_b)
    assert new_tensorizer.to_bytes() == tensorizer_b


def test_serialize_tensorizer_roundtrip_disk(en_vocab):
    tensorizer = Tensorizer(en_vocab)
    tensorizer.model = tensorizer.Model()
    with make_tempdir() as d:
        file_path = d / 'tensorizer'
        tensorizer.to_disk(file_path)
        tensorizer_d = Tensorizer(en_vocab).from_disk(file_path)
        assert tensorizer.to_bytes() == tensorizer_d.to_bytes()


def test_serialize_textcat_empty(en_vocab):
    # See issue #1105
    textcat = TextCategorizer(en_vocab, labels=['ENTITY', 'ACTION', 'MODIFIER'])
    textcat_bytes = textcat.to_bytes()
