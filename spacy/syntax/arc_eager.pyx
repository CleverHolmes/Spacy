# cython: profile=True
from __future__ import unicode_literals

import ctypes
import os

from ._state cimport State
from ._state cimport has_head, get_idx, get_s0, get_n0, get_left, get_right
from ._state cimport is_final, at_eol, pop_stack, push_stack, add_dep
from ._state cimport head_in_buffer, children_in_buffer
from ._state cimport head_in_stack, children_in_stack
from ._state cimport count_left_kids

from ..structs cimport TokenC

from .transition_system cimport do_func_t, get_cost_func_t
from .transition_system cimport move_cost_func_t, label_cost_func_t
from ..gold cimport GoldParse
from ..gold cimport GoldParseC

from libc.stdint cimport uint32_t
from libc.string cimport memcpy

from cymem.cymem cimport Pool
from .stateclass cimport StateClass


DEF NON_MONOTONIC = True
DEF USE_BREAK = True

cdef weight_t MIN_SCORE = -90000

# Break transition from here
# http://www.aclweb.org/anthology/P13-1074
cdef enum:
    SHIFT
    REDUCE
    LEFT
    RIGHT

    BREAK

    N_MOVES


MOVE_NAMES = [None] * N_MOVES
MOVE_NAMES[SHIFT] = 'S'
MOVE_NAMES[REDUCE] = 'D'
MOVE_NAMES[LEFT] = 'L'
MOVE_NAMES[RIGHT] = 'R'
MOVE_NAMES[BREAK] = 'B'


# Helper functions for the arc-eager oracle

cdef int push_cost(const State* st, const GoldParseC* gold, int target) except -1:
    cdef StateClass stcls = StateClass(st.sent_len)
    stcls.from_struct(st)
    cdef int cost = 0
    cdef int i, S_i
    for i in range(stcls.stack_depth()):
        S_i = stcls.S(i)
        if gold.heads[target] == S_i:
            cost += 1
        if gold.heads[S_i] == target and (NON_MONOTONIC or not stcls.has_head(S_i)):
            cost += 1
    cost += Break.is_valid(stcls, -1) and Break.move_cost(st, gold) == 0
    return cost


cdef int pop_cost(const State* st, const GoldParseC* gold, int target) except -1:
    cdef StateClass stcls = StateClass(st.sent_len)
    stcls.from_struct(st)
    cdef int cost = 0
    cdef int i, B_i
    for i in range(stcls.buffer_length()):
        B_i = stcls.B(i)
        cost += gold.heads[B_i] == target
        cost += gold.heads[target] == B_i
        if gold.heads[B_i] == B_i or gold.heads[B_i] < target:
            break
    return cost

cdef int arc_cost(const State* st, const GoldParseC* gold, int head, int child) except -1:
    cdef StateClass stcls = StateClass(st.sent_len)
    stcls.from_struct(st)
    if arc_is_gold(gold, head, child):
        return 0
    elif stcls.H(child) == gold.heads[child]:
        return 1
    elif gold.heads[child] >= stcls.B(0):
        return 1
    else:
        return 0


cdef bint arc_is_gold(const GoldParseC* gold, int head, int child) except -1:
    if gold.labels[child] == -1:
        return True
    elif _is_gold_root(gold, head) and _is_gold_root(gold, child):
        return True
    elif gold.heads[child] == head:
        return True
    else:
        return False


cdef bint label_is_gold(const GoldParseC* gold, int head, int child, int label) except -1:
    if gold.labels[child] == -1:
        return True
    elif label == -1:
        return True
    elif gold.labels[child] == label:
        return True
    else:
        return False


cdef bint _is_gold_root(const GoldParseC* gold, int word) except -1:
    return gold.labels[word] == -1 or gold.heads[word] == word
 

cdef class Shift:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) except -1:
        return not st.eol()

    @staticmethod
    cdef int transition(State* state, int label) except -1:
        # Set the dep label, in case we need it after we reduce
        if NON_MONOTONIC:
            state.sent[state.i].dep = label
        push_stack(state)

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        return Shift.move_cost(s, gold) + Shift.label_cost(s, gold, label)

    @staticmethod
    cdef int move_cost(const State* s, const GoldParseC* gold) except -1:
        return push_cost(s, gold, s.i)

    @staticmethod
    cdef int label_cost(const State* s, const GoldParseC* gold, int label) except -1:
        return 0


cdef class Reduce:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) except -1:
        if NON_MONOTONIC:
            return st.stack_depth() >= 2 #and not missing_brackets(s)
        else:
            return st.stack_depth() >= 2 and st.has_head(st.S(0))

    @staticmethod
    cdef int transition(State* state, int label) except -1:
        if NON_MONOTONIC and not has_head(get_s0(state)) and state.stack_len >= 2:
            add_dep(state, state.stack[-1], state.stack[0], get_s0(state).dep)
        pop_stack(state)

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        return Reduce.move_cost(s, gold) + Reduce.label_cost(s, gold, label)

    @staticmethod
    cdef int move_cost(const State* s, const GoldParseC* gold) except -1:
        if NON_MONOTONIC:
            return pop_cost(s, gold, s.stack[0])
        else:
            return children_in_buffer(s, s.stack[0], gold.heads)

    @staticmethod
    cdef int label_cost(const State* s, const GoldParseC* gold, int label) except -1:
        return 0


cdef class LeftArc:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) except -1:
        if NON_MONOTONIC:
            return st.stack_depth() >= 1 #and not missing_brackets(s)
        else:
            return st.stack_depth() >= 1 and not st.has_head(st.S(0))

    @staticmethod
    cdef int transition(State* state, int label) except -1:
        # Interpret left-arcs from EOL as attachment to root
        if at_eol(state):
            add_dep(state, state.stack[0], state.stack[0], label)
        else:
            add_dep(state, state.i, state.stack[0], label)
        pop_stack(state)

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        return LeftArc.move_cost(s, gold) + LeftArc.label_cost(s, gold, label)

    @staticmethod
    cdef int move_cost(const State* s, const GoldParseC* gold) except -1:
        if arc_is_gold(gold, s.i, s.stack[0]):
            return 0
        else:
            return pop_cost(s, gold, s.stack[0]) + arc_cost(s, gold, s.i, s.stack[0])

    @staticmethod
    cdef int label_cost(const State* s, const GoldParseC* gold, int label) except -1:
        return arc_is_gold(gold, s.i, s.stack[0]) and not label_is_gold(gold, s.i, s.stack[0], label)


cdef class RightArc:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) except -1:
        return st.stack_depth() >= 1 and not st.eol()

    @staticmethod
    cdef int transition(State* state, int label) except -1:
        add_dep(state, state.stack[0], state.i, label)
        push_stack(state)

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        return RightArc.move_cost(s, gold) + RightArc.label_cost(s, gold, label)

    @staticmethod
    cdef int move_cost(const State* s, const GoldParseC* gold) except -1:
        if arc_is_gold(gold, s.stack[0], s.i):
            return 0
        else:
            return push_cost(s, gold, s.i) + arc_cost(s, gold, s.stack[0], s.i)

    @staticmethod
    cdef int label_cost(const State* s, const GoldParseC* gold, int label) except -1:
        return arc_is_gold(gold, s.stack[0], s.i) and not label_is_gold(gold, s.stack[0], s.i, label)


cdef class Break:
    @staticmethod
    cdef bint is_valid(StateClass st, int label) except -1:
        cdef int i
        if not USE_BREAK:
            return False
        elif st.eol():
            return False
        elif st.stack_depth() < 1:
            return False
        elif NON_MONOTONIC:
            return True
        else:
            # In the Break transition paper, they have this constraint that prevents
            # Break if stack is disconnected. But, if we're doing non-monotonic parsing,
            # we prefer to relax this constraint. This is helpful in parsing whole
            # documents, because then we don't get stuck with words on the stack.
            seen_headless = False
            for i in range(st.stack_depth()):
                if not st.has_head(st.S(i)):
                    if seen_headless:
                        return False
                    else:
                        seen_headless = True
            # TODO: Constituency constraints
            return True

    @staticmethod
    cdef int transition(State* state, int label) except -1:
        state.sent[state.i-1].sent_end = True
        while state.stack_len != 0:
            if get_s0(state).head == 0:
                get_s0(state).dep = label
            state.stack -= 1
            state.stack_len -= 1

    @staticmethod
    cdef int cost(const State* s, const GoldParseC* gold, int label) except -1:
        return Break.move_cost(s, gold) + Break.label_cost(s, gold, label)

    @staticmethod
    cdef int move_cost(const State* s, const GoldParseC* gold) except -1:
        # When we break, we Reduce all of the words on the stack.
        cdef int cost = 0
        # Number of deps between S0...Sn and N0...Nn
        for i in range(s.i, s.sent_len):
            cost += children_in_stack(s, i, gold.heads)
            cost += head_in_stack(s, i, gold.heads)
        return cost
    
    @staticmethod
    cdef int label_cost(const State* s, const GoldParseC* gold, int label) except -1:
        return 0


cdef class ArcEager(TransitionSystem):
    @classmethod
    def get_labels(cls, gold_parses):
        move_labels = {SHIFT: {'': True}, REDUCE: {'': True}, RIGHT: {},
                       LEFT: {'ROOT': True}, BREAK: {'ROOT': True}}
        for raw_text, sents in gold_parses:
            for (ids, words, tags, heads, labels, iob), ctnts in sents:
                for child, head, label in zip(ids, heads, labels):
                    if label != 'ROOT':
                        if head < child:
                            move_labels[RIGHT][label] = True
                        elif head > child:
                            move_labels[LEFT][label] = True
        return move_labels

    cdef int preprocess_gold(self, GoldParse gold) except -1:
        for i in range(gold.length):
            if gold.heads[i] is None: # Missing values
                gold.c.heads[i] = i
                gold.c.labels[i] = -1
            else:
                gold.c.heads[i] = gold.heads[i]
                gold.c.labels[i] = self.strings[gold.labels[i]]
        for end, brackets in gold.brackets.items():
            for start, label_strs in brackets.items():
                gold.c.brackets[start][end] = 1
                for label_str in label_strs:
                    # Add the encoded label to the set
                    gold.brackets[end][start].add(self.strings[label_str])

    cdef Transition lookup_transition(self, object name) except *:
        if '-' in name:
            move_str, label_str = name.split('-', 1)
            label = self.label_ids[label_str]
        else:
            label = 0
        move = MOVE_NAMES.index(move_str)
        for i in range(self.n_moves):
            if self.c[i].move == move and self.c[i].label == label:
                return self.c[i]

    def move_name(self, int move, int label):
        label_str = self.strings[label]
        if label_str:
            return MOVE_NAMES[move] + '-' + label_str
        else:
            return MOVE_NAMES[move]

    cdef Transition init_transition(self, int clas, int move, int label) except *:
        # TODO: Apparent Cython bug here when we try to use the Transition()
        # constructor with the function pointers
        cdef Transition t
        t.score = 0
        t.clas = clas
        t.move = move
        t.label = label
        if move == SHIFT:
            t.is_valid = Shift.is_valid
            t.do = Shift.transition
            t.get_cost = Shift.cost
        elif move == REDUCE:
            t.is_valid = Reduce.is_valid
            t.do = Reduce.transition
            t.get_cost = Reduce.cost
        elif move == LEFT:
            t.is_valid = LeftArc.is_valid
            t.do = LeftArc.transition
            t.get_cost = LeftArc.cost
        elif move == RIGHT:
            t.is_valid = RightArc.is_valid
            t.do = RightArc.transition
            t.get_cost = RightArc.cost
        elif move == BREAK:
            t.is_valid = Break.is_valid
            t.do = Break.transition
            t.get_cost = Break.cost
        else:
            raise Exception(move)
        return t

    cdef int initialize_state(self, State* state) except -1:
        push_stack(state)

    cdef int finalize_state(self, State* state) except -1:
        cdef int root_label = self.strings['ROOT']
        for i in range(state.sent_len):
            if state.sent[i].head == 0 and state.sent[i].dep == 0:
                state.sent[i].dep = root_label

    cdef int set_valid(self, bint* output, StateClass stcls) except -1:
        cdef bint[N_MOVES] is_valid
        is_valid[SHIFT] = Shift.is_valid(stcls, -1)
        is_valid[REDUCE] = Reduce.is_valid(stcls, -1)
        is_valid[LEFT] = LeftArc.is_valid(stcls, -1)
        is_valid[RIGHT] = RightArc.is_valid(stcls, -1)
        is_valid[BREAK] = Break.is_valid(stcls, -1)
        cdef int i
        for i in range(self.n_moves):
            output[i] = is_valid[self.c[i].move]

    cdef int set_costs(self, int* output, const State* s, GoldParse gold) except -1:
        cdef int i, move, label
        cdef label_cost_func_t[N_MOVES] label_cost_funcs
        cdef move_cost_func_t[N_MOVES] move_cost_funcs
        cdef int[N_MOVES] move_costs
        for i in range(N_MOVES):
            move_costs[i] = -1
        move_cost_funcs[SHIFT] = Shift.move_cost
        move_cost_funcs[REDUCE] = Reduce.move_cost
        move_cost_funcs[LEFT] = LeftArc.move_cost
        move_cost_funcs[RIGHT] = RightArc.move_cost
        move_cost_funcs[BREAK] = Break.move_cost

        label_cost_funcs[SHIFT] = Shift.label_cost
        label_cost_funcs[REDUCE] = Reduce.label_cost
        label_cost_funcs[LEFT] = LeftArc.label_cost
        label_cost_funcs[RIGHT] = RightArc.label_cost
        label_cost_funcs[BREAK] = Break.label_cost

        cdef int* labels = gold.c.labels
        cdef int* heads = gold.c.heads

        cdef StateClass stcls = StateClass(s.sent_len)
        stcls.from_struct(s)
        self.set_valid(self._is_valid, stcls)
        for i in range(self.n_moves):
            if not self._is_valid[i]:
                output[i] = 9000
            else:
                move = self.c[i].move
                label = self.c[i].label
                if move_costs[move] == -1:
                    move_costs[move] = move_cost_funcs[move](s, &gold.c)
                output[i] = move_costs[move] + label_cost_funcs[move](s, &gold.c, label)

    cdef Transition best_valid(self, const weight_t* scores, StateClass stcls) except *:
        cdef bint[N_MOVES] is_valid
        is_valid[SHIFT] = Shift.is_valid(stcls, -1)
        is_valid[REDUCE] = Reduce.is_valid(stcls, -1)
        is_valid[LEFT] = LeftArc.is_valid(stcls, -1)
        is_valid[RIGHT] = RightArc.is_valid(stcls, -1)
        is_valid[BREAK] = Break.is_valid(stcls, -1)
        cdef Transition best
        cdef weight_t score = MIN_SCORE
        cdef int i
        for i in range(self.n_moves):
            if scores[i] > score and is_valid[self.c[i].move]:
                best = self.c[i]
                score = scores[i]
        assert best.clas < self.n_moves
        assert score > MIN_SCORE
        # Label Shift moves with the best Right-Arc label, for non-monotonic
        # actions
        if best.move == SHIFT:
            score = MIN_SCORE
            for i in range(self.n_moves):
                if self.c[i].move == RIGHT and scores[i] > score:
                    best.label = self.c[i].label
                    score = scores[i]
        return best
