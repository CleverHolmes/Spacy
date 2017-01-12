# coding: utf-8
"""Test that times like "7am" are tokenized correctly and that numbers are converted to string."""


from __future__ import unicode_literals

import pytest


@pytest.mark.xfail
@pytest.mark.parametrize('text,number', [("7am", "7"), ("11p.m.", "11")])
def test_issue736(en_tokenizer, text, number):
    tokens = en_tokenizer(text)
    assert len(tokens) == 2
    assert tokens[0].text == number
    assert tokens[0].lemma_ == number
    assert tokens[0].pos_ == 'NUM'
