from libcpp.vector cimport vector
from libc.stdint cimport uint32_t
from libc.stdint cimport uint64_t

from sparsehash.dense_hash_map cimport dense_hash_map
from _hashing cimport FixedTable
from _hashing cimport WordTree

# Circular import problems here
ctypedef size_t Lexeme_addr
ctypedef uint32_t StringHash
ctypedef dense_hash_map[StringHash, size_t] Vocab
from spacy.lexeme cimport Lexeme

from spacy.tokens cimport Tokens

# Put these above import to avoid circular import problem
ctypedef char Bits8
ctypedef uint64_t Bits64
ctypedef int ClusterID


from spacy.lexeme cimport Lexeme
from spacy.lexeme cimport Distribution
from spacy.lexeme cimport Orthography
from spacy._hashing cimport WordTree


cdef class Language:
    cdef object name
    cdef WordTree vocab
    cdef WordTree distri
    cdef WordTree ortho
    cdef dict bacov

    cpdef Tokens tokenize(self, unicode text)

    cdef Lexeme_addr lookup(self, unicode string) except 0
    cdef Lexeme_addr lookup_chunk(self, unicode string) except 0
    cdef Orthography* lookup_orth(self, unicode lex) except NULL
    cdef Distribution* lookup_dist(self, unicode lex) except NULL
    
    cdef Lexeme* new_lexeme(self, unicode key, unicode lex) except NULL
    cdef Orthography* new_orth(self, unicode lex) except NULL
    cdef Distribution* new_dist(self, unicode lex) except NULL
    
    cdef unicode unhash(self, StringHash hashed)
    
    cdef int find_split(self, unicode word, size_t length)
