# cython: profile=True
# cython: embedsignature=True
from __future__ import unicode_literals

import json
import random
from os import path
import re

from cython.operator cimport preincrement as preinc
from cython.operator cimport dereference as deref
from libc.stdio cimport fopen, fclose, fread, fwrite, FILE

from cymem.cymem cimport Pool
from murmurhash.mrmr cimport hash64
from preshed.maps cimport PreshMap

from .lexeme cimport Lexeme
from .lexeme cimport EMPTY_LEXEME
from .lexeme cimport init as lexeme_init

from .utf8string cimport slice_unicode

from . import util
from .util import read_lang_data
from .tokens import Tokens


cdef class Language:
    def __init__(self, name):
        self.name = name
        self.mem = Pool()
        self._cache = PreshMap(2 ** 25)
        self._specials = PreshMap(2 ** 16)
        rules, prefix, suffix, infix = util.read_lang_data(name)
        self._prefix_re = re.compile(prefix)
        self._suffix_re = re.compile(suffix)
        self._infix_re = re.compile(infix)
        self.lexicon = Lexicon(self.set_flags)
        if path.exists(path.join(util.DATA_DIR, name, 'lexemes')):
            self.lexicon.load(path.join(util.DATA_DIR, name, 'lexemes'))
            self.lexicon.strings.load(path.join(util.DATA_DIR, name, 'strings'))
        self._load_special_tokenization(rules)

    cpdef Tokens tokens_from_list(self, list strings):
        cdef int length = sum([len(s) for s in strings])
        cdef Tokens tokens = Tokens(self.lexicon.strings, length)
        if length == 0:
            return tokens
        cdef UniStr string_struct
        cdef unicode py_string
        cdef int idx = 0
        for i, py_string in enumerate(strings):
            slice_unicode(&string_struct, py_string, 0, len(py_string))
            tokens.push_back(idx, self.lexicon.get(&string_struct))
            idx += len(py_string) + 1
        return tokens

    cpdef Tokens tokenize(self, unicode string):
        """Tokenize a string.

        The tokenization rules are defined in three places:

        * The data/<lang>/tokenization table, which handles special cases like contractions;
        * The data/<lang>/prefix file, used to build a regex to split off prefixes;
        * The data/<lang>/suffix file, used to build a regex to split off suffixes.

        Args:
            string (unicode): The string to be tokenized. 

        Returns:
            tokens (Tokens): A Tokens object, giving access to a sequence of Lexemes.
        """
        cdef int length = len(string)
        cdef Tokens tokens = Tokens(self.lexicon.strings, length)
        if length == 0:
            return tokens
        cdef int i = 0
        cdef int start = 0
        cdef Py_UNICODE* chars = string
        cdef bint in_ws = Py_UNICODE_ISSPACE(chars[0])
        cdef UniStr span
        for i in range(1, length):
            if Py_UNICODE_ISSPACE(chars[i]) != in_ws:
                if start < i:
                    slice_unicode(&span, chars, start, i)
                    lexemes = <Lexeme**>self._cache.get(span.key)
                    if lexemes != NULL:
                        tokens.extend(start, lexemes, 0)
                    else: 
                        self._tokenize(tokens, &span, start, i)
                in_ws = not in_ws
                start = i
                if chars[i] == ' ':
                    start += 1
        i += 1
        if start < i:
            slice_unicode(&span, chars, start, i)
            lexemes = <Lexeme**>self._cache.get(span.key)
            if lexemes != NULL:
                tokens.extend(start, lexemes, 0)
            else: 
                self._tokenize(tokens, &span, start, i)
        return tokens

    cdef int _tokenize(self, Tokens tokens, UniStr* span, int start, int end) except -1:
        cdef vector[Lexeme*] prefixes
        cdef vector[Lexeme*] suffixes
        cdef hash_t orig_key
        cdef int orig_size
        orig_key = span.key
        orig_size = tokens.length
        self._split_affixes(span, &prefixes, &suffixes)
        self._attach_tokens(tokens, start, span, &prefixes, &suffixes)
        self._save_cached(&tokens.lex[orig_size], orig_key, tokens.length - orig_size)

    cdef UniStr* _split_affixes(self, UniStr* string, vector[Lexeme*] *prefixes,
                                vector[Lexeme*] *suffixes) except NULL:
        cdef size_t i
        cdef UniStr prefix
        cdef UniStr suffix
        cdef UniStr minus_pre
        cdef UniStr minus_suf
        cdef size_t last_size = 0
        while string.n != 0 and string.n != last_size:
            last_size = string.n
            pre_len = self._find_prefix(string.chars, string.n)
            if pre_len != 0:
                slice_unicode(&prefix, string.chars, 0, pre_len)
                slice_unicode(&minus_pre, string.chars, pre_len, string.n)
                # Check whether we've hit a special-case
                if minus_pre.n >= 1 and self._specials.get(minus_pre.key) != NULL:
                    string[0] = minus_pre
                    prefixes.push_back(self.lexicon.get(&prefix))
                    break
            suf_len = self._find_suffix(string.chars, string.n)
            if suf_len != 0:
                slice_unicode(&suffix, string.chars, string.n - suf_len, string.n)
                slice_unicode(&minus_suf, string.chars, 0, string.n - suf_len)
                # Check whether we've hit a special-case
                if minus_suf.n >= 1 and self._specials.get(minus_suf.key) != NULL:
                    string[0] = minus_suf
                    suffixes.push_back(self.lexicon.get(&suffix))
                    break
            if pre_len and suf_len and (pre_len + suf_len) <= string.n:
                slice_unicode(string, string.chars, pre_len, string.n - suf_len)
                prefixes.push_back(self.lexicon.get(&prefix))
                suffixes.push_back(self.lexicon.get(&suffix))
            elif pre_len:
                string[0] = minus_pre
                prefixes.push_back(self.lexicon.get(&prefix))
            elif suf_len:
                string[0] = minus_suf
                suffixes.push_back(self.lexicon.get(&suffix))
            if self._specials.get(string.key):
                break
        return string

    cdef int _attach_tokens(self, Tokens tokens,
                            int idx, UniStr* string,
                            vector[Lexeme*] *prefixes,
                            vector[Lexeme*] *suffixes) except -1:
        cdef int split
        cdef Lexeme** lexemes
        cdef Lexeme* lexeme
        cdef UniStr span
        if prefixes.size():
            idx = tokens.extend(idx, prefixes.data(), prefixes.size())
        if string.n != 0:

            lexemes = <Lexeme**>self._cache.get(string.key)
            if lexemes != NULL:
                idx = tokens.extend(idx, lexemes, 0)
            else:
                split = self._find_infix(string.chars, string.n)
                if split == 0 or split == -1:
                    idx = tokens.push_back(idx, self.lexicon.get(string))
                else:
                    slice_unicode(&span, string.chars, 0, split)
                    idx = tokens.push_back(idx, self.lexicon.get(&span))
                    slice_unicode(&span, string.chars, split, split+1)
                    idx = tokens.push_back(idx, self.lexicon.get(&span))
                    slice_unicode(&span, string.chars, split + 1, string.n)
                    idx = tokens.push_back(idx, self.lexicon.get(&span))
        cdef vector[Lexeme*].reverse_iterator it = suffixes.rbegin()
        while it != suffixes.rend():
            idx = tokens.push_back(idx, deref(it))
            preinc(it)

    cdef int _save_cached(self, Lexeme** tokens, hash_t key, int n) except -1:
        lexemes = <Lexeme**>self.mem.alloc(n + 1, sizeof(Lexeme**))
        cdef int i
        for i in range(n):
            lexemes[i] = tokens[i]
        lexemes[i + 1] = NULL
        self._cache.set(key, lexemes)

    cdef int _find_infix(self, Py_UNICODE* chars, size_t length) except -1:
        cdef unicode string = chars[:length]
        match = self._infix_re.search(string)
        return match.start() if match is not None else 0
    
    cdef int _find_prefix(self, Py_UNICODE* chars, size_t length) except -1:
        cdef unicode string = chars[:length]
        match = self._prefix_re.search(string)
        return (match.end() - match.start()) if match is not None else 0

    cdef int _find_suffix(self, Py_UNICODE* chars, size_t length) except -1:
        cdef unicode string = chars[:length]
        match = self._suffix_re.search(string)
        return (match.end() - match.start()) if match is not None else 0

    def _load_special_tokenization(self, token_rules):
        '''Load special-case tokenization rules.

        Loads special-case tokenization rules into the Language._cache cache,
        read from data/<lang>/tokenization . The special cases are loaded before
        any language data is tokenized, giving these priority.  For instance,
        the English tokenization rules map "ain't" to ["are", "not"].

        Args:
            token_rules (list): A list of (chunk, tokens) pairs, where chunk is
                a string and tokens is a list of strings.
        '''
        cdef Lexeme** lexemes
        cdef hash_t hashed
        cdef UniStr string
        for uni_string, substrings in token_rules:
            lexemes = <Lexeme**>self.mem.alloc(len(substrings) + 1, sizeof(Lexeme*))
            for i, substring in enumerate(substrings):
                slice_unicode(&string, substring, 0, len(substring))
                lexemes[i] = <Lexeme*>self.lexicon.get(&string)
            lexemes[i + 1] = NULL
            slice_unicode(&string, uni_string, 0, len(uni_string))
            self._specials.set(string.key, lexemes)
            self._cache.set(string.key, lexemes)


cdef class Lexicon:
    '''A map container for a language's Lexeme structs.
    
    Also interns UTF-8 strings, and maps them to consecutive integer IDs.
    '''
    def __init__(self, object set_flags=None):
        self.mem = Pool()
        self._map = PreshMap(2 ** 20)
        self.strings = StringStore()
        self.lexemes.push_back(&EMPTY_LEXEME)
        self.size = 1
        self.set_flags = set_flags

    cdef Lexeme* get(self, UniStr* string) except NULL:
        '''Retrieve a pointer to a Lexeme from the lexicon.'''
        cdef Lexeme* lex
        lex = <Lexeme*>self._map.get(string.key)
        if lex != NULL:
            return lex
        lex = <Lexeme*>self.mem.alloc(sizeof(Lexeme), 1)
        lex[0] = lexeme_init(self.size, string.chars[:string.n], string.key,
                self.strings, {'flags': self.set_flags(string.chars[:string.n])})
        self._map.set(string.key, lex)
        while self.lexemes.size() < (lex.id + 1):
            self.lexemes.push_back(&EMPTY_LEXEME)
        self.lexemes[lex.id] = lex
        self.size += 1
        return lex

    def __getitem__(self,  id_or_string):
        '''Retrieve a lexeme, given an int ID or a unicode string.  If a previously
        unseen unicode string is given, a new Lexeme is created and stored.

        This function relies on Cython's struct-to-dict conversion.  Python clients
        receive a dict keyed by strings (byte or unicode, depending on Python 2/3),
        with int values.  Cython clients can instead receive a Lexeme struct value.
        More efficient Cython access is provided by Lexicon.get, which returns
        a Lexeme*.

        Args:
            id_or_string (int or unicode): The integer ID of a word, or its unicode
                string.  If an int >= Lexicon.size, IndexError is raised.
                If id_or_string is neither an int nor a unicode string, ValueError
                is raised.

        Returns:
            lexeme (dict): A Lexeme struct instance, which Cython translates into
                a dict if the operator is called from Python.
        '''
        if type(id_or_string) == int:
            return self.lexemes.at(id_or_string)[0]
        cdef UniStr string
        slice_unicode(&string, id_or_string, 0, len(id_or_string))
        cdef Lexeme* lexeme = self.get(&string)
        return lexeme[0]

    def __setitem__(self, unicode uni_string, dict props):
        cdef UniStr s
        slice_unicode(&s, uni_string, 0, len(uni_string))
        cdef Lexeme* lex = self.get(&s)
        lex[0] = lexeme_init(lex.id, s.chars[:s.n], s.key, self.strings, props)

    def dump(self, loc):
        if path.exists(loc):
            assert not path.isdir(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        cdef FILE* fp = fopen(<char*>bytes_loc, 'wb')
        assert fp != NULL
        cdef size_t st
        cdef hash_t key
        for i in range(self._map.length):
            key = self._map.c_map.cells[i].key
            if key == 0:
                continue
            lexeme = <Lexeme*>self._map.c_map.cells[i].value
            st = fwrite(&key, sizeof(key), 1, fp)
            assert st == 1
            st = fwrite(lexeme, sizeof(Lexeme), 1, fp)
            assert st == 1
        st = fclose(fp)
        assert st == 0

    def load(self, loc):
        assert path.exists(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        cdef FILE* fp = fopen(<char*>bytes_loc, 'rb')
        assert fp != NULL
        cdef size_t st
        cdef Lexeme* lexeme
        cdef hash_t key
        i = 0
        while True:
            st = fread(&key, sizeof(key), 1, fp)
            if st != 1:
                break
            lexeme = <Lexeme*>self.mem.alloc(sizeof(Lexeme), 1)
            st = fread(lexeme, sizeof(Lexeme), 1, fp)
            if st != 1:
                break
            self._map.set(key, lexeme)
            while self.lexemes.size() < (lexeme.id + 1):
                self.lexemes.push_back(&EMPTY_LEXEME)
            self.lexemes[lexeme.id] = lexeme
            i += 1
            self.size += 1
        fclose(fp)
