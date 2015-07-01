spaCy
=====

spaCy is a library for industrial-strength NLP in Python and Cython.

Documentation and details: http://spacy.io/

spaCy is built on the very latest research, but it isn't researchware.  It was
designed from day 1 to be used in real products.

I left academia to make spaCy my full-time job. You can buy a commercial
license, or you can use it under the AGPL.


Features
--------

* Labelled dependency parsing (91.8% accuracy on OntoNotes 5)
* Named entity recognition (82.6% accuracy on OntoNotes 5)
* Part-of-speech tagging (97.1% accuracy on OntoNotes 5)
* Easy to use word vectors
* All strings mapped to integer IDs
* Export to numpy data arrays
* Alignment maintained to original string, ensuring easy mark up calculation
* Range of easy-to-use orthographic features.
* No pre-processing required. spaCy takes raw text as input, warts and newlines and all.

Top Pefomance
-------------

* Fastest in the world: <50ms per document.  No faster system has ever been
  announced.
* Accuracy within 1% of the current state of the art on all tasks performed
  (parsing, named entity recognition, part-of-speech tagging).  The only more
  accurate systems are an order of magnitude slower or more.

Supports
--------

* CPython 2.7
* CPython 3.4
* OSX
* Linux 
* Cygwin

Want to support:

* Visual Studio

Difficult to support:

* PyPy 2.7
* PyPy 3.4
