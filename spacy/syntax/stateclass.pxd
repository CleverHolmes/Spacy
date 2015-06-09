from libc.string cimport memcpy, memset

from cymem.cymem cimport Pool

from ..structs cimport TokenC

from ._state cimport State

from ..vocab cimport EMPTY_LEXEME


cdef class StateClass:
    cdef Pool mem
    cdef int* _stack
    cdef int* _buffer
    cdef TokenC* _sent
    cdef TokenC _empty_token
    cdef int length
    cdef int _s_i
    cdef int _b_i

    cdef int from_struct(self, const State* state) except -1

    cdef int S(self, int i) nogil
    cdef int B(self, int i) nogil
    
    cdef int H(self, int i) nogil
    
    cdef int L(self, int i, int idx) nogil
    cdef int R(self, int i, int idx) nogil

    cdef const TokenC* S_(self, int i) nogil
    cdef const TokenC* B_(self, int i) nogil

    cdef const TokenC* H_(self, int i) nogil

    cdef const TokenC* L_(self, int i, int idx) nogil
    cdef const TokenC* R_(self, int i, int idx) nogil

    cdef const TokenC* safe_get(self, int i) nogil

    cdef bint empty(self) nogil

    cdef bint eol(self) nogil

    cdef bint is_final(self) nogil

    cdef bint has_head(self, int i) nogil

    cdef int n_L(self, int i) nogil

    cdef int n_R(self, int i) nogil

    cdef bint stack_is_connected(self) nogil

    cdef int stack_depth(self) nogil
    
    cdef int buffer_length(self) nogil

    cdef void push(self) nogil

    cdef void pop(self) nogil

    cdef void add_arc(self, int head, int child, int label) nogil
    
    cdef void del_arc(self, int head, int child) nogil

    cdef void set_sent_end(self, int i) nogil

    cdef void clone(self, StateClass src) nogil


