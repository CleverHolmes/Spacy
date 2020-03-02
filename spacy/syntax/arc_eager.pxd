from cymem.cymem cimport Pool

from .stateclass cimport StateClass
from ..typedefs cimport weight_t, attr_t
from .transition_system cimport TransitionSystem, Transition
from ..gold cimport GoldParseC


cdef class ArcEager(TransitionSystem):
    pass


cdef weight_t push_cost(StateClass stcls, const GoldParseC* gold, int target) nogil
cdef weight_t arc_cost(StateClass stcls, const GoldParseC* gold, int head, int child) nogil
