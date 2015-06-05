from __future__ import unicode_literals

from ._state cimport State

from .transition_system cimport Transition
from .transition_system cimport do_func_t

from ..structs cimport TokenC, Entity

from thinc.typedefs cimport weight_t
from ..gold cimport GoldParseC
from ..gold cimport GoldParse


cdef enum:
    MISSING
    BEGIN
    IN
    LAST
    UNIT
    OUT
    N_MOVES


MOVE_NAMES = [None] * N_MOVES
MOVE_NAMES[MISSING] = 'M'
MOVE_NAMES[BEGIN] = 'B'
MOVE_NAMES[IN] = 'I'
MOVE_NAMES[LAST] = 'L'
MOVE_NAMES[UNIT] = 'U'
MOVE_NAMES[OUT] = 'O'


cdef do_func_t[N_MOVES] do_funcs


cdef bint entity_is_open(const State *s) except -1:
    return s.ents_len >= 1 and s.ent.end == 0


cdef bint _entity_is_sunk(const State *s, Transition* golds) except -1:
    if not entity_is_open(s):
        return False

    cdef const Transition* gold = &golds[s.ent.start]
    if gold.move != BEGIN and gold.move != UNIT:
        return True
    elif gold.label != s.ent.label:
        return True
    else:
        return False

cdef class BiluoPushDown(TransitionSystem):
    @classmethod
    def get_labels(cls, gold_tuples):
        move_labels = {MISSING: {'': True}, BEGIN: {}, IN: {}, LAST: {}, UNIT: {},
                       OUT: {'': True}}
        moves = ('M', 'B', 'I', 'L', 'U')
        for raw_text, sents in gold_tuples:
            for (ids, words, tags, heads, labels, biluo), _ in sents:
                for i, ner_tag in enumerate(biluo):
                    if ner_tag != 'O' and ner_tag != '-':
                        if ner_tag.count('-') != 1:
                            raise ValueError(ner_tag)
                        _, label = ner_tag.split('-')
                        for move_str in ('B', 'I', 'L', 'U'):
                            move_labels[moves.index(move_str)][label] = True
        return move_labels

    def move_name(self, int move, int label):
        if move == OUT:
            return 'O'
        elif move == 'MISSING':
            return 'M'
        else:
            return MOVE_NAMES[move] + '-' + self.strings[label]

    cdef int preprocess_gold(self, GoldParse gold) except -1:
        for i in range(gold.length):
            gold.c.ner[i] = self.lookup_transition(gold.ner[i])

    cdef Transition lookup_transition(self, object name) except *:
        if name == '-':
            move_str = 'M'
            label = 0
        elif '-' in name:
            move_str, label_str = name.split('-', 1)
            label = self.strings[label_str]
        else:
            move_str = name
            label = 0
        move = MOVE_NAMES.index(move_str)
        for i in range(self.n_moves):
            if self.c[i].move == move and self.c[i].label == label:
                return self.c[i]
        else:
            raise KeyError(name)

    cdef Transition init_transition(self, int clas, int move, int label) except *:
        # TODO: Apparent Cython bug here when we try to use the Transition()
        # constructor with the function pointers
        cdef Transition t
        t.score = 0
        t.clas = clas
        t.move = move
        t.label = label
        if move == MISSING:
            t.is_valid = Missing.is_valid
            t.do = Missing.transition
            t.get_cost = Missing.cost
        elif move == BEGIN:
            t.is_valid = Begin.is_valid
            t.do = Begin.transition
            t.get_cost = Begin.cost
        elif move == IN:
            t.is_valid = In.is_valid
            t.do = In.transition
            t.get_cost = In.cost
        elif move == LAST:
            t.is_valid = Last.is_valid
            t.do = Last.transition
            t.get_cost = Last.cost
        elif move == UNIT:
            t.is_valid = Unit.is_valid
            t.do = Unit.transition
            t.get_cost = Unit.cost
        elif move == OUT:
            t.is_valid = Out.is_valid
            t.do = Out.transition
            t.get_cost = Out.cost
        else:
            raise Exception(move)
        return t

    cdef Transition best_valid(self, const weight_t* scores, const State* s) except *:
        cdef int best = -1
        cdef weight_t score = -90000
        cdef const Transition* m
        cdef int i
        for i in range(self.n_moves):
            m = &self.c[i]
            if m.is_valid(s, m.label) and scores[i] > score:
                best = i
                score = scores[i]
        assert best >= 0
        cdef Transition t = self.c[best]
        t.score = score
        return t

    cdef int set_valid(self, bint* output, const State* s) except -1:
        cdef int i
        for i in range(self.n_moves):
            m = &self.c[i]
            output[i] = m.is_valid(s, m.label)


cdef class Missing:
    @staticmethod
    cdef bint is_valid(const State* s, int label) except -1:
        return False

    @staticmethod
    cdef int transition(State* s, int label) except -1:
        raise NotImplementedError

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        return 9000


cdef class Begin:
    @staticmethod
    cdef bint is_valid(const State* s, int label) except -1:
        return label != 0 and not entity_is_open(s)

    @staticmethod
    cdef int transition(State* s, int label) except -1:
        s.ent += 1
        s.ents_len += 1
        s.ent.start = s.i
        s.ent.label = label
        s.ent.end = 0
        s.sent[s.i].ent_iob = 3
        s.sent[s.i].ent_type = label
        s.i += 1

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        if not Begin.is_valid(s, label):
            return 9000
        cdef int g_act = gold.ner[s.i].move
        cdef int g_tag = gold.ner[s.i].label

        if g_act == MISSING:
            return 0
        if g_act == BEGIN:
            # B, Gold B --> Label match
            return label != g_tag
        else:
            # B, Gold I --> False (P)
            # B, Gold L --> False (P)
            # B, Gold O --> False (P)
            # B, Gold U --> False (P)
            return 1

cdef class In:
    @staticmethod
    cdef bint is_valid(const State* s, int label) except -1:
        return entity_is_open(s) and label != 0 and s.ent.label == label
    
    @staticmethod
    cdef int transition(State* s, int label) except -1:
        s.sent[s.i].ent_iob = 1
        s.sent[s.i].ent_type = label
        s.i += 1

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        if not In.is_valid(s, label):
            return 9000
        move = IN
        cdef int next_act = gold.ner[s.i+1].move if s.i < s.sent_len else OUT
        cdef int g_act = gold.ner[s.i].move
        cdef int g_tag = gold.ner[s.i].label
        cdef bint is_sunk = _entity_is_sunk(s, gold.ner)
        
        if g_act == MISSING:
            return 0
        elif g_act == BEGIN:
            # I, Gold B --> True (P of bad open entity sunk, R of this entity sunk)
            return 0
        elif g_act == IN:
            # I, Gold I --> True (label forced by prev, if mismatch, P and R both sunk)
            return 0
        elif g_act == LAST:
            # I, Gold L --> True iff this entity sunk and next tag == O
            return not (is_sunk and (next_act == OUT or next_act == MISSING))
        elif g_act == OUT:
            # I, Gold O --> True iff next tag == O
            return not (next_act == OUT or next_act == MISSING)
        elif g_act == UNIT:
            # I, Gold U --> True iff next tag == O
            return next_act != OUT
        else:
            return 1



cdef class Last:
    @staticmethod
    cdef bint is_valid(const State* s, int label) except -1:
        return entity_is_open(s) and label != 0 and s.ent.label == label

    @staticmethod
    cdef int transition(State* s, int label) except -1:
        s.ent.end = s.i+1
        s.sent[s.i].ent_iob = 1
        s.sent[s.i].ent_type = label
        s.i += 1

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        if not Last.is_valid(s, label):
            return 9000
        move = LAST

        cdef int g_act = gold.ner[s.i].move
        cdef int g_tag = gold.ner[s.i].label
        
        if g_act == MISSING:
            return 0
        elif g_act == BEGIN:
            # L, Gold B --> True
            return 0
        elif g_act == IN:
            # L, Gold I --> True iff this entity sunk
            return not _entity_is_sunk(s, gold.ner)
        elif g_act == LAST:
            # L, Gold L --> True
            return 0
        elif g_act == OUT:
            # L, Gold O --> True
            return 0
        elif g_act == UNIT:
            # L, Gold U --> True
            return 0
        else:
            return 1


cdef class Unit:
    @staticmethod
    cdef bint is_valid(const State* s, int label) except -1:
        return label != 0 and not entity_is_open(s)

    @staticmethod
    cdef int transition(State* s, int label) except -1:
        s.ent += 1
        s.ents_len += 1
        s.ent.start = s.i
        s.ent.label = label
        s.ent.end = s.i+1
        s.sent[s.i].ent_iob = 3
        s.sent[s.i].ent_type = label
        s.i += 1

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        if not Unit.is_valid(s, label):
            return 9000
        cdef int g_act = gold.ner[s.i].move
        cdef int g_tag = gold.ner[s.i].label

        if g_act == MISSING:
            return 0
        elif g_act == UNIT:
            # U, Gold U --> True iff tag match
            return label != g_tag
        else:
            # U, Gold B --> False
            # U, Gold I --> False
            # U, Gold L --> False
            # U, Gold O --> False
            return 1


cdef class Out:
    @staticmethod
    cdef bint is_valid(const State* s, int label) except -1:
        return not entity_is_open(s)

    @staticmethod
    cdef int transition(State* s, int label) except -1:
        s.sent[s.i].ent_iob = 2
        s.i += 1
    
    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        if not Out.is_valid(s, label):
            return 9000

        cdef int g_act = gold.ner[s.i].move
        cdef int g_tag = gold.ner[s.i].label


        if g_act == MISSING:
            return 0
        elif g_act == BEGIN:
            # O, Gold B --> False
            return 1
        elif g_act == IN:
            # O, Gold I --> True
            return 0
        elif g_act == LAST:
            # O, Gold L --> True
            return 0
        elif g_act == OUT:
            # O, Gold O --> True
            return 0
        elif g_act == UNIT:
            # O, Gold U --> False
            return 1
        else:
            return 1
    
"""

# TODO: Move this logic into the cost functions
cdef int _get_cost(int move, int label, const State* s, const GoldParseC* gold) except -1:
    cdef bint is_sunk = _entity_is_sunk(s, gold.ner)
    cdef int next_act = gold.ner[s.i+1].move if s.i < s.sent_len else OUT
    cdef bint is_gold = _is_gold(move, label, gold.ner[s.i].move,
                                gold.ner[s.i].label, next_act, is_sunk)
    return not is_gold


cdef bint _is_gold(int act, int tag, int g_act, int g_tag,
                   int next_act, bint is_sunk):
    if g_act == MISSING:
        return True
    if act == BEGIN:
        if g_act == BEGIN:
            # B, Gold B --> Label match
            return tag == g_tag
        else:
            # B, Gold I --> False (P)
            # B, Gold L --> False (P)
            # B, Gold O --> False (P)
            # B, Gold U --> False (P)
            return False
    elif act == IN:
        if g_act == BEGIN:
            # I, Gold B --> True (P of bad open entity sunk, R of this entity sunk)
            return True
        elif g_act == IN:
            # I, Gold I --> True (label forced by prev, if mismatch, P and R both sunk)
            return True
        elif g_act == LAST:
            # I, Gold L --> True iff this entity sunk and next tag == O
            return is_sunk and (next_act == OUT or next_act == MISSING)
        elif g_act == OUT:
            # I, Gold O --> True iff next tag == O
            return next_act == OUT or next_act == MISSING
        elif g_act == UNIT:
            # I, Gold U --> True iff next tag == O
            return next_act == OUT
    elif act == LAST:
        if g_act == BEGIN:
            # L, Gold B --> True
            return True
        elif g_act == IN:
            # L, Gold I --> True iff this entity sunk
            return is_sunk
        elif g_act == LAST:
            # L, Gold L --> True
            return True
        elif g_act == OUT:
            # L, Gold O --> True
            return True
        elif g_act == UNIT:
            # L, Gold U --> True
            return True
    elif act == OUT:
        if g_act == BEGIN:
            # O, Gold B --> False
            return False
        elif g_act == IN:
            # O, Gold I --> True
            return True
        elif g_act == LAST:
            # O, Gold L --> True
            return True
        elif g_act == OUT:
            # O, Gold O --> True
            return True
        elif g_act == UNIT:
            # O, Gold U --> False
            return False
    elif act == UNIT:
        if g_act == UNIT:
            # U, Gold U --> True iff tag match
            return tag == g_tag
        else:
            # U, Gold B --> False
            # U, Gold I --> False
            # U, Gold L --> False
            # U, Gold O --> False
            return False
"""


class OracleError(Exception):
    pass


class UnknownMove(Exception):
    pass
