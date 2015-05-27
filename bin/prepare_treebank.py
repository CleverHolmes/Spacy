"""Convert OntoNotes into a json format.

doc: {
    id: string,
    paragraphs: [{
        raw: string,
        sents: [int],
        tokens: [{
            start: int,
            tag: string,
            head: int,
            dep: string}],
        ner: [{
            start: int,
            end: int,
            label: string}],
        brackets: [{
            start: int,
            end: int,
            label: string}]}]}

Consumes output of spacy/munge/align_raw.py
"""
from __future__ import unicode_literals
import plac
import json
from os import path
import os
import re
import codecs

from spacy.munge import read_ptb
from spacy.munge import read_conll
from spacy.munge import read_ner


def _iter_raw_files(raw_loc):
    files = json.load(open(raw_loc))
    for f in files:
        yield f


def format_doc(file_id, raw_paras, ptb_text, dep_text, ner_text):
    ptb_sents = read_ptb.split(ptb_text)
    dep_sents = read_conll.split(dep_text)
    if len(ptb_sents) != len(dep_sents):
        return None
    if ner_text is not None:
        ner_sents = read_ner.split(ner_text)
    else:
        ner_sents = [None] * len(ptb_sents)

    i = 0
    doc = {'id': file_id}
    if raw_paras is None:
        doc['paragraphs'] = [format_para(None, ptb_sents, dep_sents, ner_sents)]
    else:
        doc['paragraphs'] = []
        for raw_sents in raw_paras:
            doc['paragraphs'].append(
                format_para(
                    ' '.join(raw_sents).replace('<SEP>', ''),
                    ptb_sents[i:i+len(raw_sents)],
                    dep_sents[i:i+len(raw_sents)],
                    ner_sents[i:i+len(raw_sents)]))
            i += len(raw_sents)
    return doc


def format_para(raw_text, ptb_sents, dep_sents, ner_sents):
    para = {
        'raw': raw_text,
        'sents': [],
        'tokens': [],
        'brackets': []}
    offset = 0
    assert len(ptb_sents) == len(dep_sents) == len(ner_sents)
    for ptb_text, dep_text, ner_text in zip(ptb_sents, dep_sents, ner_sents):
        _, annot = read_conll.parse(dep_text, strip_bad_periods=True)
        if ner_text is not None:
            _, ner = read_ner.parse(ner_text, strip_bad_periods=True)
        else:
            ner = ['-' for _ in annot]
        for token_id, (token, token_ent) in enumerate(zip(annot, ner)):
            para['tokens'].append(format_token(offset, token_id, token, token_ent))

        _, brackets = read_ptb.parse(ptb_text, strip_bad_periods=True)
        for label, start, end in brackets:
            if start != end:
                para['brackets'].append({
                    'label': label,
                    'first': start + offset,
                    'last': (end-1) + offset})
        offset += len(annot)
        para['sents'].append(offset)
    return para


def format_token(offset, token_id, token, ner):
    head = (token['head'] + offset) if token['head'] != -1 else -1
    return {
        'id': offset + token_id,
        'orth': token['word'],
        'tag': token['tag'],
        'head': head,
        'dep': token['dep'],
        'ner': ner}


def read_file(*pieces):
    loc = path.join(*pieces)
    if not path.exists(loc):
        return None
    else:
        return codecs.open(loc, 'r', 'utf8').read().strip()


def get_file_names(section_dir, subsection):
    filenames = []
    for fn in os.listdir(path.join(section_dir, subsection)):
        filenames.append(fn.rsplit('.', 1)[0])
    return list(sorted(set(filenames)))


def read_wsj_with_source(onto_dir, raw_dir):
    # Now do WSJ, with source alignment
    onto_dir = path.join(onto_dir, 'data', 'english', 'annotations', 'nw', 'wsj')
    docs = {}
    for i in range(25):
        section = str(i) if i >= 10 else ('0' + str(i))
        raw_loc = path.join(raw_dir, 'wsj%s.json' % section)
        for j, (filename, raw_paras) in enumerate(_iter_raw_files(raw_loc)):
            if section == '00':
                j += 1
            if section == '04' and filename == '55':
                continue
            ptb = read_file(onto_dir, section, '%s.parse' % filename)
            dep = read_file(onto_dir, section, '%s.parse.dep' % filename)
            ner = read_file(onto_dir, section, '%s.name' % filename)
            if ptb is not None and dep is not None:
                docs[filename] = format_doc(filename, raw_paras, ptb, dep, ner)
    return docs


def get_doc(onto_dir, file_path, wsj_docs):
    filename = file_path.rsplit('/', 1)[1]
    if filename in wsj_docs:
        return wsj_docs[filename]
    else:
        ptb = read_file(onto_dir, file_path + '.parse')
        dep = read_file(onto_dir, file_path + '.parse.dep')
        ner = read_file(onto_dir, file_path + '.name')
        if ptb is not None and dep is not None:
            return format_doc(filename, None, ptb, dep, ner)
        else:
            return None

def read_ids(loc):
    return open(loc).read().strip().split('\n')

def main(onto_dir, raw_dir, out_dir):
    wsj_docs = read_wsj_with_source(onto_dir, raw_dir)

    for partition in ('train', 'test', 'development'):
        ids = read_ids(path.join(onto_dir, '%s.id' % partition))
        out_loc = path.join(out_dir, '%s.json' % partition)
        docs = []
        for file_path in ids:
            doc = get_doc(onto_dir, file_path, wsj_docs)
            if doc is not None:
                docs.append(doc)
        with open(out_loc, 'w') as file_:
            json.dump(docs, file_, indent=4)


if __name__ == '__main__':
    plac.call(main)
