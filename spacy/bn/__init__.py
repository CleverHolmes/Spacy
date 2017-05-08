# coding: utf8
from __future__ import unicode_literals

from .tokenizer_exceptions import TOKENIZER_EXCEPTIONS
from .punctuation import TOKENIZER_PREFIXES, TOKENIZER_SUFFIXES, TOKENIZER_INFIXES
from .tag_map import TAG_MAP
from .stop_words import STOP_WORDS
from .lemmatizer import LEMMA_RULES

from ..language_data import BASE_EXCEPTIONS
from ..language import Language
from ..attrs import LANG
from ..util import update_exc


class Bengali(Language):
    lang = 'bn'

    class Defaults(Language.Defaults):
        lex_attr_getters = dict(Language.Defaults.lex_attr_getters)
        lex_attr_getters[LANG] = lambda text: 'bn'

        tokenizer_exceptions = update_exc(BASE_EXCEPTIONS, TOKENIZER_EXCEPTIONS)
        tag_map = TAG_MAP
        stop_words = STOP_WORDS
        lemma_rules = LEMMA_RULES

        prefixes = tuple(TOKENIZER_PREFIXES)
        suffixes = tuple(TOKENIZER_SUFFIXES)
        infixes = tuple(TOKENIZER_INFIXES)


__all__ = ['Bengali']
