from .stop_words import STOP_WORDS
from .tag_map import TAG_MAP
from ...language import Language
from ...attrs import LANG
from .lex_attrs import LEX_ATTRS
from ...language import Language


class CzechDefaults(Language.Defaults):
    lex_attr_getters = dict(Language.Defaults.lex_attr_getters)
    lex_attr_getters.update(LEX_ATTRS)
    lex_attr_getters[LANG] = lambda text: "cs"
    tag_map = TAG_MAP
    stop_words = STOP_WORDS
    lex_attr_getters = LEX_ATTRS


class Czech(Language):
    lang = "cs"
    Defaults = CzechDefaults


__all__ = ["Czech"]
