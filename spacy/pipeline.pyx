from .syntax.parser cimport Parser
from .syntax.ner cimport BiluoPushDown
from .syntax.arc_eager cimport ArcEager
from .vocab cimport Vocab
from .tagger cimport Tagger


cdef class EntityRecognizer(Parser):
    @classmethod
    def load(cls, path, Vocab vocab):
        return Parser.load(path, vocab, BiluoPushDown)

    @classmethod
    def blank(cls, Vocab vocab, **cfg):
        if 'actions' not in cfg:
            cfg['actions'] = {}
            entity_types = cfg.get('entity_types', [''])
            for action_type in (1, 2, 3, 4):
                cfg['actions'][action_type] = {ent_type: True for ent_type in entity_types}
        return Parser.blank(vocab, BiluoPushDown, **cfg)


cdef class DependencyParser(Parser):
    @classmethod
    def load(cls, path, Vocab vocab):
        return Parser.load(path, vocab, ArcEager)

    @classmethod
    def blank(cls, Vocab vocab, **cfg):
        if 'actions' not in cfg:
            cfg['actions'] = {1: {'': True}, 2: {'': True}, 3: {}, 4: {},
                              5: {'ROOT': True}}
            for label in cfg.get('left_labels', []):
                cfg['actions'][3][label] = True
            for label in cfg.get('right_labels', []):
                cfg['actions'][4][label] = True
            for label in cfg.get('break_labels', []):
                cfg['actions'][5][label] = True
        return Parser.blank(vocab, ArcEager, **cfg)


__all__ = [Tagger, DependencyParser, EntityRecognizer]
