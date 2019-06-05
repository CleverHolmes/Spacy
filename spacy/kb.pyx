# cython: infer_types=True
# cython: profile=True
# coding: utf8
from collections import OrderedDict
from cpython.exc cimport PyErr_CheckSignals

from spacy import util
from spacy.errors import Errors, Warnings, user_warning

from cymem.cymem cimport Pool
from preshed.maps cimport PreshMap

from cpython.mem cimport PyMem_Malloc
from cpython.exc cimport PyErr_SetFromErrno

from libc.stdio cimport FILE, fopen, fclose, fread, fwrite, feof, fseek
from libc.stdint cimport int32_t, int64_t
from libc.stdlib cimport qsort

from .typedefs cimport hash_t

from os import path
from libcpp.vector cimport vector



cdef class Candidate:

    def __init__(self, KnowledgeBase kb, entity_hash, entity_freq, entity_vector, alias_hash, prior_prob):
        self.kb = kb
        self.entity_hash = entity_hash
        self.entity_freq = entity_freq
        self.entity_vector = entity_vector
        self.alias_hash = alias_hash
        self.prior_prob = prior_prob

    @property
    def entity(self):
        """RETURNS (uint64): hash of the entity's KB ID/name"""
        return self.entity_hash

    @property
    def entity_(self):
        """RETURNS (unicode): ID/name of this entity in the KB"""
        return self.kb.vocab.strings[self.entity_hash]

    @property
    def alias(self):
        """RETURNS (uint64): hash of the alias"""
        return self.alias_hash

    @property
    def alias_(self):
        """RETURNS (unicode): ID of the original alias"""
        return self.kb.vocab.strings[self.alias_hash]

    @property
    def entity_freq(self):
        return self.entity_freq

    @property
    def entity_vector(self):
        return self.entity_vector

    @property
    def prior_prob(self):
        return self.prior_prob


cdef class KnowledgeBase:

    def __init__(self, Vocab vocab, entity_vector_length):
        self.vocab = vocab
        self.mem = Pool()
        self.entity_vector_length = entity_vector_length

        self._entry_index = PreshMap()
        self._alias_index = PreshMap()

        # Should we initialize self._entries and self._aliases_table to specific starting size ?

        self.vocab.strings.add("")
        self._create_empty_vectors(dummy_hash=self.vocab.strings[""])

    def __len__(self):
        return self.get_size_entities()

    def get_size_entities(self):
        return len(self._entry_index)

    def get_entity_strings(self):
        return [self.vocab.strings[x] for x in self._entry_index]

    def get_size_aliases(self):
        return len(self._alias_index)

    def get_alias_strings(self):
        return [self.vocab.strings[x] for x in self._alias_index]

    def add_entity(self, unicode entity, float prob, vector[float] entity_vector):
        """
        Add an entity to the KB, optionally specifying its log probability based on corpus frequency
        Return the hash of the entity ID/name at the end.
        """
        cdef hash_t entity_hash = self.vocab.strings.add(entity)

        # Return if this entity was added before
        if entity_hash in self._entry_index:
            user_warning(Warnings.W018.format(entity=entity))
            return

        if len(entity_vector) != self.entity_vector_length:
            # TODO: proper error
            raise ValueError("Entity vector length should have been", self.entity_vector_length)

        vector_index = self.c_add_vector(entity_vector=entity_vector)

        new_index = self.c_add_entity(entity_hash=entity_hash,
                                      prob=prob,
                                      vector_index=vector_index,
                                      feats_row=-1)  # Features table currently not implemented
        self._entry_index[entity_hash] = new_index

        return entity_hash

    cpdef set_entities(self, entity_list, prob_list, vector_list):
        nr_entities = len(entity_list)
        self._entry_index = PreshMap(nr_entities+1)
        self._entries = entry_vec(nr_entities+1)

        i = 0
        cdef EntryC entry
        while i < nr_entities:
            entity_vector = entity_list[i]
            if len(entity_vector) != self.entity_vector_length:
                # TODO: proper error
                raise ValueError("Entity vector length should have been", self.entity_vector_length)

            entity_hash = self.vocab.strings.add(entity_vector)
            entry.entity_hash = entity_hash
            entry.prob = prob_list[i]

            vector_index = self.c_add_vector(entity_vector=vector_list[i])
            entry.vector_index = vector_index

            entry.feats_row = -1   # Features table currently not implemented

            self._entries[i+1] = entry
            self._entry_index[entity_hash] = i+1

            i += 1

    # TODO: this method is untested
    cpdef set_aliases(self, alias_list, entities_list, probabilities_list):
        nr_aliases = len(alias_list)
        self._alias_index = PreshMap(nr_aliases+1)
        self._aliases_table = alias_vec(nr_aliases+1)

        i = 0
        cdef AliasC alias
        cdef int32_t dummy_value = 342
        while i <= nr_aliases:
            alias_hash = self.vocab.strings.add(alias_list[i])
            entities = entities_list[i]
            probabilities = probabilities_list[i]

            nr_candidates = len(entities)
            entry_indices = vector[int64_t](nr_candidates)
            probs = vector[float](nr_candidates)

            for j in range(0, nr_candidates):
                entity = entities[j]
                entity_hash = self.vocab.strings[entity]
                if not entity_hash in self._entry_index:
                    raise ValueError(Errors.E134.format(alias=alias, entity=entity))

                entry_index = <int64_t>self._entry_index.get(entity_hash)
                entry_indices[j] = entry_index

            alias.entry_indices = entry_indices
            alias.probs = probs

            self._aliases_table[i] = alias
            self._alias_index[alias_hash] = i

            i += 1

    def add_alias(self, unicode alias, entities, probabilities):
        """
        For a given alias, add its potential entities and prior probabilies to the KB.
        Return the alias_hash at the end
        """

        # Throw an error if the length of entities and probabilities are not the same
        if not len(entities) == len(probabilities):
            raise ValueError(Errors.E132.format(alias=alias,
                                                entities_length=len(entities),
                                                probabilities_length=len(probabilities)))

        # Throw an error if the probabilities sum up to more than 1 (allow for some rounding errors)
        prob_sum = sum(probabilities)
        if prob_sum > 1.00001:
            raise ValueError(Errors.E133.format(alias=alias, sum=prob_sum))

        cdef hash_t alias_hash = self.vocab.strings.add(alias)

        # Check whether this alias was added before
        if alias_hash in self._alias_index:
            user_warning(Warnings.W017.format(alias=alias))
            return

        cdef vector[int64_t] entry_indices
        cdef vector[float] probs

        for entity, prob in zip(entities, probabilities):
            entity_hash = self.vocab.strings[entity]
            if not entity_hash in self._entry_index:
                raise ValueError(Errors.E134.format(alias=alias, entity=entity))

            entry_index = <int64_t>self._entry_index.get(entity_hash)
            entry_indices.push_back(int(entry_index))
            probs.push_back(float(prob))

        new_index = self.c_add_aliases(alias_hash=alias_hash, entry_indices=entry_indices, probs=probs)
        self._alias_index[alias_hash] = new_index

        return alias_hash

    def get_candidates(self, unicode alias):
        cdef hash_t alias_hash = self.vocab.strings[alias]
        alias_index = <int64_t>self._alias_index.get(alias_hash)
        alias_entry = self._aliases_table[alias_index]

        return [Candidate(kb=self,
                          entity_hash=self._entries[entry_index].entity_hash,
                          entity_freq=self._entries[entry_index].prob,
                          entity_vector=self._vectors_table[self._entries[entry_index].vector_index],
                          alias_hash=alias_hash,
                          prior_prob=prob)
                for (entry_index, prob) in zip(alias_entry.entry_indices, alias_entry.probs)
                if entry_index != 0]


    def dump(self, loc):
        cdef Writer writer = Writer(loc)
        writer.write_header(self.get_size_entities(), self.entity_vector_length)

        # dumping the entity vectors in their original order
        i = 0
        for entity_vector in self._vectors_table:
            for element in entity_vector:
                writer.write_vector_element(element)
            i = i+1

        # dumping the entry records in the order in which they are in the _entries vector.
        # index 0 is a dummy object not stored in the _entry_index and can be ignored.
        i = 1
        for entry_hash, entry_index in sorted(self._entry_index.items(), key=lambda x: x[1]):
            entry = self._entries[entry_index]
            assert entry.entity_hash == entry_hash
            assert entry_index == i
            writer.write_entry(entry.entity_hash, entry.prob, entry.vector_index)
            i = i+1

        writer.write_alias_length(self.get_size_aliases())

        # dumping the aliases in the order in which they are in the _alias_index vector.
        # index 0 is a dummy object not stored in the _aliases_table and can be ignored.
        i = 1
        for alias_hash, alias_index in sorted(self._alias_index.items(), key=lambda x: x[1]):
            alias = self._aliases_table[alias_index]
            assert alias_index == i

            candidate_length = len(alias.entry_indices)
            writer.write_alias_header(alias_hash, candidate_length)

            for j in range(0, candidate_length):
                writer.write_alias(alias.entry_indices[j], alias.probs[j])

            i = i+1

        writer.close()

    cpdef load_bulk(self, loc):
        cdef hash_t entity_hash
        cdef hash_t alias_hash
        cdef int64_t entry_index
        cdef float prob
        cdef int32_t vector_index
        cdef EntryC entry
        cdef AliasC alias
        cdef float vector_element

        cdef Reader reader = Reader(loc)

        # STEP 0: load header and initialize KB
        cdef int64_t nr_entities
        cdef int64_t entity_vector_length
        reader.read_header(&nr_entities, &entity_vector_length)

        self.entity_vector_length = entity_vector_length
        self._entry_index = PreshMap(nr_entities+1)
        self._entries = entry_vec(nr_entities+1)
        self._vectors_table = float_matrix(nr_entities+1)

        # STEP 1: load entity vectors
        cdef int i = 0
        cdef int j = 0
        while i < nr_entities:
            entity_vector = float_vec(entity_vector_length)
            j = 0
            while j < entity_vector_length:
                reader.read_vector_element(&vector_element)
                entity_vector[j] = vector_element
                j = j+1
            self._vectors_table[i] = entity_vector
            i = i+1

        # STEP 2: load entities
        # we assume that the entity data was written in sequence
        # index 0 is a dummy object not stored in the _entry_index and can be ignored.
        i = 1
        while i <= nr_entities:
            reader.read_entry(&entity_hash, &prob, &vector_index)

            entry.entity_hash = entity_hash
            entry.prob = prob
            entry.vector_index = vector_index
            entry.feats_row = -1    # Features table currently not implemented

            self._entries[i] = entry
            self._entry_index[entity_hash] = i

            i += 1

        # check that all entities were read in properly
        assert nr_entities == self.get_size_entities()

        # STEP 3: load aliases

        cdef int64_t nr_aliases
        reader.read_alias_length(&nr_aliases)
        self._alias_index = PreshMap(nr_aliases+1)
        self._aliases_table = alias_vec(nr_aliases+1)

        cdef int64_t nr_candidates
        cdef vector[int64_t] entry_indices
        cdef vector[float] probs

        i = 1
        # we assume the alias data was written in sequence
        # index 0 is a dummy object not stored in the _entry_index and can be ignored.
        while i <= nr_aliases:
            reader.read_alias_header(&alias_hash, &nr_candidates)
            entry_indices = vector[int64_t](nr_candidates)
            probs = vector[float](nr_candidates)

            for j in range(0, nr_candidates):
                reader.read_alias(&entry_index, &prob)
                entry_indices[j] = entry_index
                probs[j] = prob

            alias.entry_indices = entry_indices
            alias.probs = probs

            self._aliases_table[i] = alias
            self._alias_index[alias_hash] = i

            i += 1

        # check that all aliases were read in properly
        assert nr_aliases == self.get_size_aliases()


cdef class Writer:
    def __init__(self, object loc):
        if path.exists(loc):
            assert not path.isdir(loc), "%s is directory." % loc
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        self._fp = fopen(<char*>bytes_loc, 'wb')
        assert self._fp != NULL
        fseek(self._fp, 0, 0)

    def close(self):
        cdef size_t status = fclose(self._fp)
        assert status == 0

    cdef int write_header(self, int64_t nr_entries, int64_t entity_vector_length) except -1:
        self._write(&nr_entries, sizeof(nr_entries))
        self._write(&entity_vector_length, sizeof(entity_vector_length))

    cdef int write_vector_element(self, float element) except -1:
        self._write(&element, sizeof(element))

    cdef int write_entry(self, hash_t entry_hash, float entry_prob, int32_t vector_index) except -1:
        self._write(&entry_hash, sizeof(entry_hash))
        self._write(&entry_prob, sizeof(entry_prob))
        self._write(&vector_index, sizeof(vector_index))
        # Features table currently not implemented and not written to file

    cdef int write_alias_length(self, int64_t alias_length) except -1:
        self._write(&alias_length, sizeof(alias_length))

    cdef int write_alias_header(self, hash_t alias_hash, int64_t candidate_length) except -1:
        self._write(&alias_hash, sizeof(alias_hash))
        self._write(&candidate_length, sizeof(candidate_length))

    cdef int write_alias(self, int64_t entry_index, float prob) except -1:
        self._write(&entry_index, sizeof(entry_index))
        self._write(&prob, sizeof(prob))

    cdef int _write(self, void* value, size_t size) except -1:
        status = fwrite(value, size, 1, self._fp)
        assert status == 1, status


cdef class Reader:
    def __init__(self, object loc):
        assert path.exists(loc)
        assert not path.isdir(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        self._fp = fopen(<char*>bytes_loc, 'rb')
        if not self._fp:
            PyErr_SetFromErrno(IOError)
        status = fseek(self._fp, 0, 0)  # this can be 0 if there is no header

    def __dealloc__(self):
        fclose(self._fp)

    cdef int read_header(self, int64_t* nr_entries, int64_t* entity_vector_length) except -1:
        status = self._read(nr_entries, sizeof(int64_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading header from input file")

        status = self._read(entity_vector_length, sizeof(int64_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading header from input file")

    cdef int read_vector_element(self, float* element) except -1:
        status = self._read(element, sizeof(float))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading entity vector from input file")

    cdef int read_entry(self, hash_t* entity_hash, float* prob, int32_t* vector_index) except -1:
        status = self._read(entity_hash, sizeof(hash_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading entity hash from input file")

        status = self._read(prob, sizeof(float))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading entity prob from input file")

        status = self._read(vector_index, sizeof(int32_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading entity vector from input file")

        if feof(self._fp):
            return 0
        else:
            return 1

    cdef int read_alias_length(self, int64_t* alias_length) except -1:
        status = self._read(alias_length, sizeof(int64_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading alias length from input file")

    cdef int read_alias_header(self, hash_t* alias_hash, int64_t* candidate_length) except -1:
        status = self._read(alias_hash, sizeof(hash_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading alias hash from input file")

        status = self._read(candidate_length, sizeof(int64_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading candidate length from input file")

    cdef int read_alias(self, int64_t* entry_index, float* prob) except -1:
        status = self._read(entry_index, sizeof(int64_t))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading entry index for alias from input file")

        status = self._read(prob, sizeof(float))
        if status < 1:
            if feof(self._fp):
                return 0  # end of file
            raise IOError("error reading prob for entity/alias from input file")

    cdef int _read(self, void* value, size_t size) except -1:
        status = fread(value, size, 1, self._fp)
        return status


