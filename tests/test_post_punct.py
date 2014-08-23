from __future__ import unicode_literals

from spacy.en import lookup
from spacy.en import tokenize
from spacy.en import unhash

import pytest


@pytest.fixture
def close_puncts():
    return [')', ']', '}', '*']


def test_close(close_puncts):
    word_str = 'Hello'
    for p in close_puncts:
        string = word_str + p
        tokens = tokenize(string)
        assert len(tokens) == 2
        assert unhash(tokens[1].lex) == p
        assert unhash(tokens[0].lex) == word_str


def test_two_different_close(close_puncts):
    word_str = 'Hello'
    for p in close_puncts:
        string = word_str + p + "'"
        tokens = tokenize(string)
        assert len(tokens) == 3
        assert unhash(tokens[0].lex) == word_str
        assert unhash(tokens[1].lex) == p
        assert unhash(tokens[2].lex) == "'"


def test_three_same_close(close_puncts):
    word_str = 'Hello'
    for p in close_puncts:
        string = word_str + p + p + p
        tokens = tokenize(string)
        assert len(tokens) == 4
        assert unhash(tokens[0].lex) == word_str
        assert unhash(tokens[1].lex) == p
