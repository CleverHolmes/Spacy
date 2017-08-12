# cython: infer_types=True
cimport numpy as np
import numpy
from cpython.ref cimport PyObject, Py_INCREF, Py_XDECREF
from thinc.extra.search cimport Beam
from thinc.extra.search import MaxViolation
from thinc.typedefs cimport hash_t, class_t

from .transition_system cimport TransitionSystem, Transition
from .stateclass cimport StateClass
from ..gold cimport GoldParse
from ..tokens.doc cimport Doc


# These are passed as callbacks to thinc.search.Beam
cdef int _transition_state(void* _dest, void* _src, class_t clas, void* _moves) except -1:
    dest = <StateClass>_dest
    src = <StateClass>_src
    moves = <const Transition*>_moves
    dest.clone(src)
    moves[clas].do(dest.c, moves[clas].label)


cdef int _check_final_state(void* _state, void* extra_args) except -1:
    return (<StateClass>_state).is_final()


def _cleanup(Beam beam):
    for i in range(beam.width):
        Py_XDECREF(<PyObject*>beam._states[i].content)
        Py_XDECREF(<PyObject*>beam._parents[i].content)


cdef hash_t _hash_state(void* _state, void* _) except 0:
    state = <StateClass>_state
    if state.c.is_final():
        return 1
    else:
        return state.c.hash()


cdef class ParserBeam(object):
    cdef public TransitionSystem moves
    cdef public object docs
    cdef public object golds
    cdef public object beams

    def __init__(self, TransitionSystem moves, docs, golds,
            int width=4, float density=0.001):
        self.moves = moves
        self.docs = docs
        self.golds = golds
        self.beams = []
        cdef Doc doc
        cdef Beam beam
        for doc in docs:
            beam = Beam(self.moves.n_moves, width, density)
            beam.initialize(self.moves.init_beam_state, doc.length, doc.c)
            self.beams.append(beam)
    
    @property
    def is_done(self):
        return all(beam.is_done for beam in self.beams)

    def __getitem__(self, i):
        return self.beams[i]

    def __len__(self):
        return len(self.beams)

    def advance(self, scores, follow_gold=False):
        cdef Beam beam
        for i, beam in enumerate(self.beams):
            self._set_scores(beam, scores[i])
            if self.golds is not None:
                self._set_costs(beam, self.golds[i], follow_gold=follow_gold)
        if follow_gold:
            assert self.golds is not None
            beam.advance(_transition_state, NULL, <void*>self.moves.c)
        else:
            beam.advance(_transition_state, _hash_state, <void*>self.moves.c)
        beam.check_done(_check_final_state, NULL)

    def _set_scores(self, Beam beam, scores):
        for i in range(beam.size):
            state = <StateClass>beam.at(i)
            for j in range(beam.nr_class):
                beam.scores[i][j] = scores[i, j]
            self.moves.set_valid(beam.is_valid[i], state.c)

    def _set_costs(self, Beam beam, GoldParse gold, int follow_gold=False):
        for i in range(beam.size):
            state = <StateClass>beam.at(i)
            self.moves.set_costs(beam.is_valid[i], beam.costs[i], state, gold)
            if follow_gold:
                for j in range(beam.nr_class):
                    beam.is_valid[i][j] *= beam.costs[i][j] <= 0
 

def get_token_ids(states, int n_tokens):
    cdef StateClass state
    cdef np.ndarray ids = numpy.zeros((len(states), n_tokens),
                                      dtype='i', order='C')
    c_ids = <int*>ids.data
    for i, state in enumerate(states):
        if not state.is_final():
            state.c.set_context_tokens(c_ids, n_tokens)
        c_ids += ids.shape[1]
    return ids


def update_beam(TransitionSystem moves, int nr_feature,
                docs, tokvecs, golds,
                state2vec, vec2scores, drop=0., sgd=None,
                losses=None, int width=4, float density=0.001):
    pbeam = ParserBeam(moves, docs, golds,
                       width=width, density=density)
    gbeam = ParserBeam(moves, docs, golds,
                       width=width, density=density)
    beam_map = {}
    backprops = []
    violns = [MaxViolation() for _ in range(len(docs))]
    example_ids = list(range(len(docs)))
    while not pbeam.is_done and not gbeam.is_done:
        states, p_indices, g_indices = get_states(example_ids, pbeam, gbeam, beam_map)

        token_ids = get_token_ids(states, nr_feature)
        vectors, bp_vectors = state2vec.begin_update(token_ids, drop=drop)
        scores, bp_scores = vec2scores.begin_update(vectors, drop=drop)
        
        backprops.append((token_ids, bp_vectors, bp_scores))

        p_scores = [scores[indices] for indices in p_indices]
        g_scores = [scores[indices] for indices in g_indices]
        pbeam.advance(p_scores)
        gbeam.advance(g_scores, follow_gold=True)

        for i, violn in enumerate(violns):
            violn.check_crf(pbeam[i], gbeam[i])
    
    histories = [(v.p_hist + v.g_hist) for v in violns]
    losses = [(v.p_probs + v.g_probs) for v in violns]
    states_d_scores = get_gradient(moves.n_moves, beam_map,
                                   histories, losses)
    return states_d_scores, backprops


def get_states(example_ids, pbeams, gbeams, beam_map):
    states = []
    seen = {}
    p_indices = []
    g_indices = []
    cdef Beam pbeam, gbeam
    for eg_id, pbeam, gbeam in zip(example_ids, pbeams, gbeams):
        p_indices.append([])
        for j in range(pbeam.size):
            key = tuple([eg_id] + pbeam.histories[j])
            seen[key] = len(states)
            p_indices[-1].append(len(states))
            states.append(<StateClass>pbeam.at(j))
        beam_map.update(seen)
        g_indices.append([])
        for i in range(gbeam.size):
            key = tuple([eg_id] + gbeam.histories[i])
            if key in seen:
                g_indices[-1].append(seen[key])
            else:
                g_indices[-1].append(len(states))
                beam_map[key] = len(states)
                states.append(<StateClass>gbeam.at(i))

    p_indices = numpy.asarray(p_indices, dtype='i')
    g_indices = numpy.asarray(g_indices, dtype='i')
    return states, p_indices, g_indices


def get_gradient(nr_class, beam_map, histories, losses):
    """
    The global model assigns a loss to each parse. The beam scores
    are additive, so the same gradient is applied to each action
    in the history. This gives the gradient of a single *action*
    for a beam state -- so we have "the gradient of loss for taking
    action i given history H."
    """
    nr_step = max(len(hist) for hist in histories)
    nr_beam = len(histories)
    grads = [numpy.zeros((nr_beam, nr_class), dtype='f') for _ in range(nr_step)]
    for hist, loss in zip(histories, losses):
        key = tuple()
        for j, clas in enumerate(hist):
            grads[j][i, clas] = loss
            key = key + clas
            i = beam_map[key]
    return grads


