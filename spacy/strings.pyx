# cython: infer_types=True
# coding: utf8
from __future__ import unicode_literals, absolute_import

cimport cython
from libc.string cimport memcpy
from libc.stdint cimport uint64_t, uint32_t
from murmurhash.mrmr cimport hash64, hash32
from preshed.maps cimport map_iter, key_t
from libc.stdint cimport uint32_t
import ujson
import dill

from .typedefs cimport hash_t
from . import util


cpdef hash_t hash_string(unicode string) except 0:
    chars = string.encode('utf8')
    return hash_utf8(chars, len(chars))


cdef hash_t hash_utf8(char* utf8_string, int length) nogil:
    return hash64(utf8_string, length, 1)


cdef uint32_t hash32_utf8(char* utf8_string, int length) nogil:
    return hash32(utf8_string, length, 1)


cdef unicode _decode(const Utf8Str* string):
    cdef int i, length
    if string.s[0] < sizeof(string.s) and string.s[0] != 0:
        return string.s[1:string.s[0]+1].decode('utf8')
    elif string.p[0] < 255:
        return string.p[1:string.p[0]+1].decode('utf8')
    else:
        i = 0
        length = 0
        while string.p[i] == 255:
            i += 1
            length += 255
        length += string.p[i]
        i += 1
        return string.p[i:length + i].decode('utf8')


cdef Utf8Str _allocate(Pool mem, const unsigned char* chars, uint32_t length) except *:
    cdef int n_length_bytes
    cdef int i
    cdef Utf8Str string
    cdef uint32_t ulength = length
    if length < sizeof(string.s):
        string.s[0] = <unsigned char>length
        memcpy(&string.s[1], chars, length)
        return string
    elif length < 255:
        string.p = <unsigned char*>mem.alloc(length + 1, sizeof(unsigned char))
        string.p[0] = length
        memcpy(&string.p[1], chars, length)
        assert string.s[0] >= sizeof(string.s) or string.s[0] == 0, string.s[0]
        return string
    else:
        i = 0
        n_length_bytes = (length // 255) + 1
        string.p = <unsigned char*>mem.alloc(length + n_length_bytes, sizeof(unsigned char))
        for i in range(n_length_bytes-1):
            string.p[i] = 255
        string.p[n_length_bytes-1] = length % 255
        memcpy(&string.p[n_length_bytes], chars, length)
        assert string.s[0] >= sizeof(string.s) or string.s[0] == 0, string.s[0]
        return string


cdef class StringStore:
    """Map strings to and from integer IDs."""
    def __init__(self, strings=None, freeze=False):
        """Create the StringStore.

        strings (iterable): A sequence of unicode strings to add to the store.
        RETURNS (StringStore): The newly constructed object.
        """
        self.mem = Pool()
        self._map = PreshMap()
        self._oov = PreshMap()
        self._resize_at = 10000
        self.c = <Utf8Str*>self.mem.alloc(self._resize_at, sizeof(Utf8Str))
        self.size = 1
        self.is_frozen = freeze
        if strings is not None:
            for string in strings:
                _ = self[string]

    property size:
        def __get__(self):
            return self.size -1

    def __len__(self):
        """The number of strings in the store.

        RETURNS (int): The number of strings in the store.
        """
        return self.size-1

    def __getitem__(self, object string_or_id):
        """Retrieve a string from a given integer ID, or vice versa.

        string_or_id (bytes or unicode or int): The value to encode.
        Returns (unicode or int): The value to be retrieved.
        """
        if isinstance(string_or_id, basestring) and len(string_or_id) == 0:
            return 0
        elif string_or_id == 0:
            return u''

        cdef bytes byte_string
        cdef const Utf8Str* utf8str
        cdef uint64_t int_id
        cdef uint32_t oov_id
        if isinstance(string_or_id, (int, long)):
            int_id = string_or_id
            oov_id = string_or_id
            if int_id < <uint64_t>self.size:
                return _decode(&self.c[int_id])
            else:
                utf8str = <Utf8Str*>self._oov.get(oov_id)
                if utf8str is not NULL:
                    return _decode(utf8str)
                else:
                    raise IndexError(string_or_id)
        else:
            if isinstance(string_or_id, bytes):
                byte_string = <bytes>string_or_id
            elif isinstance(string_or_id, unicode):
                byte_string = (<unicode>string_or_id).encode('utf8')
            else:
                raise TypeError(type(string_or_id))
            utf8str = self._intern_utf8(byte_string, len(byte_string))
            if utf8str is NULL:
                # TODO: We need to use 32 bit here, for compatibility with the
                # vocabulary values. This makes birthday paradox probabilities
                # pretty bad.
                # We could also get unlucky here, and hash into a value that
                # collides with the 'real' strings.
                return hash32_utf8(byte_string, len(byte_string))
            else:
                return utf8str - self.c

    def __contains__(self, unicode string not None):
        """Check whether a string is in the store.

        string (unicode): The string to check.
        RETURNS (bool): Whether the store contains the string.
        """
        if len(string) == 0:
            return True
        cdef hash_t key = hash_string(string)
        return self._map.get(key) is not NULL

    def __iter__(self):
        """Iterate over the strings in the store, in order.

        YIELDS (unicode): A string in the store.
        """
        cdef int i
        for i in range(self.size):
            yield _decode(&self.c[i]) if i > 0 else u''
        # TODO: Iterate OOV here?

    def __reduce__(self):
        strings = [""]
        for i in range(1, self.size):
            string = &self.c[i]
            py_string = _decode(string)
            strings.append(py_string)
        return (StringStore, (strings,), None, None, None)

    def to_disk(self, path):
        """Save the current state to a directory.

        path (unicode or Path): A path to a directory, which will be created if
            it doesn't exist. Paths may be either strings or `Path`-like objects.
        """
        path = util.ensure_path(path)
        strings = list(self)
        with path.open('w') as file_:
            ujson.dump(strings, file_)

    def from_disk(self, path):
        """Loads state from a directory. Modifies the object in place and
        returns it.

        path (unicode or Path): A path to a directory. Paths may be either
            strings or `Path`-like objects.
        RETURNS (StringStore): The modified `StringStore` object.
        """
        path = util.ensure_path(path)
        with path.open('r') as file_:
            strings = ujson.load(file_)
        self._reset_and_load(strings)
        return self

    def to_bytes(self, **exclude):
        """Serialize the current state to a binary string.

        **exclude: Named attributes to prevent from being serialized.
        RETURNS (bytes): The serialized form of the `StringStore` object.
        """
        return ujson.dumps(list(self))

    def from_bytes(self, bytes_data, **exclude):
        """Load state from a binary string.

        bytes_data (bytes): The data to load from.
        **exclude: Named attributes to prevent from being loaded.
        RETURNS (StringStore): The `StringStore` object.
        """
        strings = ujson.loads(bytes_data)
        self._reset_and_load(strings)
        return self

    def set_frozen(self, bint is_frozen):
        # TODO
        self.is_frozen = is_frozen

    def flush_oov(self):
        self._oov = PreshMap()

    def _reset_and_load(self, strings, freeze=False):
        self.mem = Pool()
        self._map = PreshMap()
        self._oov = PreshMap()
        self._resize_at = 10000
        self.c = <Utf8Str*>self.mem.alloc(self._resize_at, sizeof(Utf8Str))
        self.size = 1
        for string in strings:
            _ = self[string]
        self.is_frozen = freeze

    cdef const Utf8Str* intern_unicode(self, unicode py_string):
        # 0 means missing, but we don't bother offsetting the index.
        cdef bytes byte_string = py_string.encode('utf8')
        return self._intern_utf8(byte_string, len(byte_string))

    @cython.final
    cdef const Utf8Str* _intern_utf8(self, char* utf8_string, int length):
        # TODO: This function's API/behaviour is an unholy mess...
        # 0 means missing, but we don't bother offsetting the index.
        cdef hash_t key = hash_utf8(utf8_string, length)
        cdef Utf8Str* value = <Utf8Str*>self._map.get(key)
        if value is not NULL:
            return value
        value = <Utf8Str*>self._oov.get(key)
        if value is not NULL:
            return value
        if self.is_frozen:
            # OOV store uses 32 bit hashes. Pretty ugly :(
            key32 = hash32_utf8(utf8_string, length)
            # Important: Make the OOV store own the memory. That way it's trivial
            # to flush them all.
            value = <Utf8Str*>self._oov.mem.alloc(1, sizeof(Utf8Str))
            value[0] = _allocate(self._oov.mem, <unsigned char*>utf8_string, length)
            self._oov.set(key32, value)
            return NULL

        if self.size == self._resize_at:
            self._realloc()
        self.c[self.size] = _allocate(self.mem, <unsigned char*>utf8_string, length)
        self._map.set(key, <void*>&self.c[self.size])
        self.size += 1
        return &self.c[self.size-1]

    def _realloc(self):
        # We want to map straight to pointers, but they'll be invalidated if
        # we resize our array. So, first we remap to indices, then we resize,
        # then we can acquire the new pointers.
        cdef Pool tmp_mem = Pool()
        keys = <key_t*>tmp_mem.alloc(self.size, sizeof(key_t))
        cdef key_t key
        cdef void* value
        cdef const Utf8Str ptr
        cdef int i = 0
        cdef size_t offset
        while map_iter(self._map.c_map, &i, &key, &value):
            # Find array index with pointer arithmetic
            offset = ((<Utf8Str*>value) - self.c)
            keys[offset] = key

        self._resize_at *= 2
        cdef size_t new_size = self._resize_at * sizeof(Utf8Str)
        self.c = <Utf8Str*>self.mem.realloc(self.c, new_size)

        self._map = PreshMap(self.size)
        for i in range(self.size):
            if keys[i]:
                self._map.set(keys[i], &self.c[i])
