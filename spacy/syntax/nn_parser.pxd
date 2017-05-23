from thinc.typedefs cimport atom_t

from .stateclass cimport StateClass
from .arc_eager cimport TransitionSystem
from ..vocab cimport Vocab
from ..tokens.doc cimport Doc
from ..structs cimport TokenC
from ._state cimport StateC


cdef class Parser:
    cdef readonly Vocab vocab
    cdef public object model
    cdef readonly TransitionSystem moves
    cdef readonly object cfg

    cdef void _parse_step(self, StateC* state,
            int* token_ids, float* scores, int* is_valid,
            const float* feat_weights, int nr_class, int nr_feat) nogil

    #cdef int parseC(self, TokenC* tokens, int length, int nr_feat) nogil
