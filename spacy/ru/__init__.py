# encoding: utf8
from __future__ import unicode_literals, print_function

from ..language import Language
from ..attrs import LANG
from ..tokens import Doc
from .language_data import *


class RussianTokenizer(object):
    try:
        from pymorphy2 import MorphAnalyzer
    except ImportError:
        raise ImportError(
            "The Russian tokenizer requires the pymorphy2 library: "
            "try to fix it with "
            "pip install pymorphy2==0.8")

    _morph = MorphAnalyzer()

    def __init__(self, spacy_tokenizer, cls, nlp=None):
        self.vocab = nlp.vocab if nlp else cls.create_vocab(nlp)
        self._spacy_tokenizer = spacy_tokenizer

    def __call__(self, text):
        words = [self._normalize(RussianTokenizer._get_word(token))
                 for token in self._spacy_tokenizer(text)]

        return Doc(self.vocab, words, [False] * len(words))

    @staticmethod
    def _get_word(token):
        return token.lemma_ if len(token.lemma_) > 0 else token.text

    @classmethod
    def _normalize(cls, word):
        return cls._morph.parse(word)[0].normal_form


class RussianDefaults(Language.Defaults):
    lex_attr_getters = dict(Language.Defaults.lex_attr_getters)
    lex_attr_getters[LANG] = lambda text: 'ru'

    tokenizer_exceptions = TOKENIZER_EXCEPTIONS
    stop_words = STOP_WORDS

    @classmethod
    def create_tokenizer(cls, nlp=None):
        tokenizer = super(RussianDefaults, cls).create_tokenizer(nlp)
        return RussianTokenizer(tokenizer, cls, nlp)


class Russian(Language):
    lang = 'ru'

    Defaults = RussianDefaults
