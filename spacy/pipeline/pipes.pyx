# cython: infer_types=True
# cython: profile=True
# coding: utf8
from __future__ import unicode_literals

import numpy
import srsly
import random
from collections import OrderedDict
from thinc.api import chain
from thinc.v2v import Affine, Maxout, Softmax
from thinc.misc import LayerNorm
from thinc.neural.util import to_categorical
from thinc.neural.util import get_array_module

from spacy.kb import KnowledgeBase
from .functions import merge_subtokens
from ..tokens.doc cimport Doc
from ..syntax.nn_parser cimport Parser
from ..syntax.ner cimport BiluoPushDown
from ..syntax.arc_eager cimport ArcEager
from ..morphology cimport Morphology
from ..vocab cimport Vocab

from ..syntax import nonproj
from ..attrs import POS, ID
from ..parts_of_speech import X
from .._ml import Tok2Vec, build_tagger_model, cosine
from .._ml import build_text_classifier, build_simple_cnn_text_classifier
from .._ml import build_bow_text_classifier, build_nel_encoder
from .._ml import link_vectors_to_models, zero_init, flatten
from .._ml import masked_language_model, create_default_optimizer
from ..errors import Errors, TempErrors
from .. import util


def _load_cfg(path):
    if path.exists():
        return srsly.read_json(path)
    else:
        return {}


class Pipe(object):
    """This class is not instantiated directly. Components inherit from it, and
    it defines the interface that components should follow to function as
    components in a spaCy analysis pipeline.
    """

    name = None

    @classmethod
    def Model(cls, *shape, **kwargs):
        """Initialize a model for the pipe."""
        raise NotImplementedError

    def __init__(self, vocab, model=True, **cfg):
        """Create a new pipe instance."""
        raise NotImplementedError

    def __call__(self, doc):
        """Apply the pipe to one document. The document is
        modified in-place, and returned.

        Both __call__ and pipe should delegate to the `predict()`
        and `set_annotations()` methods.
        """
        self.require_model()
        scores, tensors = self.predict([doc])
        self.set_annotations([doc], scores, tensors=tensors)
        return doc

    def require_model(self):
        """Raise an error if the component's model is not initialized."""
        if getattr(self, "model", None) in (None, True, False):
            raise ValueError(Errors.E109.format(name=self.name))

    def pipe(self, stream, batch_size=128, n_threads=-1):
        """Apply the pipe to a stream of documents.

        Both __call__ and pipe should delegate to the `predict()`
        and `set_annotations()` methods.
        """
        for docs in util.minibatch(stream, size=batch_size):
            docs = list(docs)
            scores, tensors = self.predict(docs)
            self.set_annotations(docs, scores, tensor=tensors)
            yield from docs

    def predict(self, docs):
        """Apply the pipeline's model to a batch of docs, without
        modifying them.
        """
        self.require_model()
        raise NotImplementedError

    def set_annotations(self, docs, scores, tensors=None):
        """Modify a batch of documents, using pre-computed scores."""
        raise NotImplementedError

    def update(self, docs, golds, drop=0.0, sgd=None, losses=None):
        """Learn from a batch of documents and gold-standard information,
        updating the pipe's model.

        Delegates to predict() and get_loss().
        """
        self.require_model()
        raise NotImplementedError

    def rehearse(self, docs, sgd=None, losses=None, **config):
        pass

    def get_loss(self, docs, golds, scores):
        """Find the loss and gradient of loss for the batch of
        documents and their predicted scores."""
        raise NotImplementedError

    def add_label(self, label):
        """Add an output label, to be predicted by the model.

        It's possible to extend pre-trained models with new labels,
        but care should be taken to avoid the "catastrophic forgetting"
        problem.
        """
        raise NotImplementedError

    def create_optimizer(self):
        return create_default_optimizer(self.model.ops, **self.cfg.get("optimizer", {}))

    def begin_training(
        self, get_gold_tuples=lambda: [], pipeline=None, sgd=None, **kwargs
    ):
        """Initialize the pipe for training, using data exampes if available.
        If no model has been initialized yet, the model is added."""
        if self.model is True:
            self.model = self.Model(**self.cfg)
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    def use_params(self, params):
        """Modify the pipe's model, to use the given parameter values."""
        with self.model.use_params(params):
            yield

    def to_bytes(self, exclude=tuple(), **kwargs):
        """Serialize the pipe to a bytestring.

        exclude (list): String names of serialization fields to exclude.
        RETURNS (bytes): The serialized object.
        """
        serialize = OrderedDict()
        serialize["cfg"] = lambda: srsly.json_dumps(self.cfg)
        if self.model not in (True, False, None):
            serialize["model"] = self.model.to_bytes
        serialize["vocab"] = self.vocab.to_bytes
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        return util.to_bytes(serialize, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        """Load the pipe from a bytestring."""

        def load_model(b):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                self.model = self.Model(**self.cfg)
            self.model.from_bytes(b)

        deserialize = OrderedDict()
        deserialize["cfg"] = lambda b: self.cfg.update(srsly.json_loads(b))
        deserialize["vocab"] = lambda b: self.vocab.from_bytes(b)
        deserialize["model"] = load_model
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_bytes(bytes_data, deserialize, exclude)
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        """Serialize the pipe to disk."""
        serialize = OrderedDict()
        serialize["cfg"] = lambda p: srsly.write_json(p, self.cfg)
        serialize["vocab"] = lambda p: self.vocab.to_disk(p)
        if self.model not in (None, True, False):
            serialize["model"] = lambda p: p.open("wb").write(self.model.to_bytes())
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        """Load the pipe from disk."""

        def load_model(p):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                self.model = self.Model(**self.cfg)
            self.model.from_bytes(p.open("rb").read())

        deserialize = OrderedDict()
        deserialize["cfg"] = lambda p: self.cfg.update(_load_cfg(p))
        deserialize["vocab"] = lambda p: self.vocab.from_disk(p)
        deserialize["model"] = load_model
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self


class Tensorizer(Pipe):
    """Pre-train position-sensitive vectors for tokens."""

    name = "tensorizer"

    @classmethod
    def Model(cls, output_size=300, **cfg):
        """Create a new statistical model for the class.

        width (int): Output size of the model.
        embed_size (int): Number of vectors in the embedding table.
        **cfg: Config parameters.
        RETURNS (Model): A `thinc.neural.Model` or similar instance.
        """
        input_size = util.env_opt("token_vector_width", cfg.get("input_size", 96))
        return zero_init(Affine(output_size, input_size, drop_factor=0.0))

    def __init__(self, vocab, model=True, **cfg):
        """Construct a new statistical model. Weights are not allocated on
        initialisation.

        vocab (Vocab): A `Vocab` instance. The model must share the same
            `Vocab` instance with the `Doc` objects it will process.
        model (Model): A `Model` instance or `True` to allocate one later.
        **cfg: Config parameters.

        EXAMPLE:
            >>> from spacy.pipeline import TokenVectorEncoder
            >>> tok2vec = TokenVectorEncoder(nlp.vocab)
            >>> tok2vec.model = tok2vec.Model(128, 5000)
        """
        self.vocab = vocab
        self.model = model
        self.input_models = []
        self.cfg = dict(cfg)
        self.cfg.setdefault("cnn_maxout_pieces", 3)

    def __call__(self, doc):
        """Add context-sensitive vectors to a `Doc`, e.g. from a CNN or LSTM
        model. Vectors are set to the `Doc.tensor` attribute.

        docs (Doc or iterable): One or more documents to add vectors to.
        RETURNS (dict or None): Intermediate computations.
        """
        tokvecses = self.predict([doc])
        self.set_annotations([doc], tokvecses)
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1):
        """Process `Doc` objects as a stream.

        stream (iterator): A sequence of `Doc` objects to process.
        batch_size (int): Number of `Doc` objects to group.
        YIELDS (iterator): A sequence of `Doc` objects, in order of input.
        """
        for docs in util.minibatch(stream, size=batch_size):
            docs = list(docs)
            tensors = self.predict(docs)
            self.set_annotations(docs, tensors)
            yield from docs

    def predict(self, docs):
        """Return a single tensor for a batch of documents.

        docs (iterable): A sequence of `Doc` objects.
        RETURNS (object): Vector representations for each token in the docs.
        """
        self.require_model()
        inputs = self.model.ops.flatten([doc.tensor for doc in docs])
        outputs = self.model(inputs)
        return self.model.ops.unflatten(outputs, [len(d) for d in docs])

    def set_annotations(self, docs, tensors):
        """Set the tensor attribute for a batch of documents.

        docs (iterable): A sequence of `Doc` objects.
        tensors (object): Vector representation for each token in the docs.
        """
        for doc, tensor in zip(docs, tensors):
            if tensor.shape[0] != len(doc):
                raise ValueError(Errors.E076.format(rows=tensor.shape[0], words=len(doc)))
            doc.tensor = tensor

    def update(self, docs, golds, state=None, drop=0.0, sgd=None, losses=None):
        """Update the model.

        docs (iterable): A batch of `Doc` objects.
        golds (iterable): A batch of `GoldParse` objects.
        drop (float): The dropout rate.
        sgd (callable): An optimizer.
        RETURNS (dict): Results from the update.
        """
        self.require_model()
        if isinstance(docs, Doc):
            docs = [docs]
        inputs = []
        bp_inputs = []
        for tok2vec in self.input_models:
            tensor, bp_tensor = tok2vec.begin_update(docs, drop=drop)
            inputs.append(tensor)
            bp_inputs.append(bp_tensor)
        inputs = self.model.ops.xp.hstack(inputs)
        scores, bp_scores = self.model.begin_update(inputs, drop=drop)
        loss, d_scores = self.get_loss(docs, golds, scores)
        d_inputs = bp_scores(d_scores, sgd=sgd)
        d_inputs = self.model.ops.xp.split(d_inputs, len(self.input_models), axis=1)
        for d_input, bp_input in zip(d_inputs, bp_inputs):
            bp_input(d_input, sgd=sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += loss
        return loss

    def get_loss(self, docs, golds, prediction):
        ids = self.model.ops.flatten([doc.to_array(ID).ravel() for doc in docs])
        target = self.vocab.vectors.data[ids]
        d_scores = (prediction - target) / prediction.shape[0]
        loss = (d_scores ** 2).sum()
        return loss, d_scores

    def begin_training(self, gold_tuples=lambda: [], pipeline=None, sgd=None, **kwargs):
        """Allocate models, pre-process training data and acquire an
        optimizer.

        gold_tuples (iterable): Gold-standard training data.
        pipeline (list): The pipeline the model is part of.
        """
        if pipeline is not None:
            for name, model in pipeline:
                if getattr(model, "tok2vec", None):
                    self.input_models.append(model.tok2vec)
        if self.model is True:
            self.model = self.Model(**self.cfg)
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd


class Tagger(Pipe):
    """Pipeline component for part-of-speech tagging.

    DOCS: https://spacy.io/api/tagger
    """

    name = "tagger"

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self._rehearsal_model = None
        self.cfg = OrderedDict(sorted(cfg.items()))
        self.cfg.setdefault("cnn_maxout_pieces", 2)

    @property
    def labels(self):
        return tuple(self.vocab.morphology.tag_names)

    @property
    def tok2vec(self):
        if self.model in (None, True, False):
            return None
        else:
            return chain(self.model.tok2vec, flatten)

    def __call__(self, doc):
        tags, tokvecs = self.predict([doc])
        self.set_annotations([doc], tags, tensors=tokvecs)
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1):
        for docs in util.minibatch(stream, size=batch_size):
            docs = list(docs)
            tag_ids, tokvecs = self.predict(docs)
            self.set_annotations(docs, tag_ids, tensors=tokvecs)
            yield from docs

    def predict(self, docs):
        self.require_model()
        if not any(len(doc) for doc in docs):
            # Handle cases where there are no tokens in any docs.
            n_labels = len(self.labels)
            guesses = [self.model.ops.allocate((0, n_labels)) for doc in docs]
            tokvecs = self.model.ops.allocate((0, self.model.tok2vec.nO))
            return guesses, tokvecs
        tokvecs = self.model.tok2vec(docs)
        scores = self.model.softmax(tokvecs)
        guesses = []
        for doc_scores in scores:
            doc_guesses = doc_scores.argmax(axis=1)
            if not isinstance(doc_guesses, numpy.ndarray):
                doc_guesses = doc_guesses.get()
            guesses.append(doc_guesses)
        return guesses, tokvecs

    def set_annotations(self, docs, batch_tag_ids, tensors=None):
        if isinstance(docs, Doc):
            docs = [docs]
        cdef Doc doc
        cdef int idx = 0
        cdef Vocab vocab = self.vocab
        for i, doc in enumerate(docs):
            doc_tag_ids = batch_tag_ids[i]
            if hasattr(doc_tag_ids, "get"):
                doc_tag_ids = doc_tag_ids.get()
            for j, tag_id in enumerate(doc_tag_ids):
                # Don't clobber preset POS tags
                if doc.c[j].tag == 0 and doc.c[j].pos == 0:
                    # Don't clobber preset lemmas
                    lemma = doc.c[j].lemma
                    vocab.morphology.assign_tag_id(&doc.c[j], tag_id)
                    if lemma != 0 and lemma != doc.c[j].lex.orth:
                        doc.c[j].lemma = lemma
                idx += 1
            if tensors is not None and len(tensors):
                if isinstance(doc.tensor, numpy.ndarray) \
                and not isinstance(tensors[i], numpy.ndarray):
                    doc.extend_tensor(tensors[i].get())
                else:
                    doc.extend_tensor(tensors[i])
            doc.is_tagged = True

    def update(self, docs, golds, drop=0., sgd=None, losses=None):
        self.require_model()
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.

        tag_scores, bp_tag_scores = self.model.begin_update(docs, drop=drop)
        loss, d_tag_scores = self.get_loss(docs, golds, tag_scores)
        bp_tag_scores(d_tag_scores, sgd=sgd)

        if losses is not None:
            losses[self.name] += loss

    def rehearse(self, docs, drop=0., sgd=None, losses=None):
        """Perform a 'rehearsal' update, where we try to match the output of
        an initial model.
        """
        if self._rehearsal_model is None:
            return
        guesses, backprop = self.model.begin_update(docs, drop=drop)
        target = self._rehearsal_model(docs)
        gradient = guesses - target
        backprop(gradient, sgd=sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += (gradient**2).sum()

    def get_loss(self, docs, golds, scores):
        scores = self.model.ops.flatten(scores)
        tag_index = {tag: i for i, tag in enumerate(self.labels)}
        cdef int idx = 0
        correct = numpy.zeros((scores.shape[0],), dtype="i")
        guesses = scores.argmax(axis=1)
        known_labels = numpy.ones((scores.shape[0], 1), dtype="f")
        for gold in golds:
            for tag in gold.tags:
                if tag is None:
                    correct[idx] = guesses[idx]
                elif tag in tag_index:
                    correct[idx] = tag_index[tag]
                else:
                    correct[idx] = 0
                    known_labels[idx] = 0.
                idx += 1
        correct = self.model.ops.xp.array(correct, dtype="i")
        d_scores = scores - to_categorical(correct, nb_classes=scores.shape[1])
        d_scores *= self.model.ops.asarray(known_labels)
        loss = (d_scores**2).sum()
        d_scores = self.model.ops.unflatten(d_scores, [len(d) for d in docs])
        return float(loss), d_scores

    def begin_training(self, get_gold_tuples=lambda: [], pipeline=None, sgd=None,
                       **kwargs):
        orig_tag_map = dict(self.vocab.morphology.tag_map)
        new_tag_map = OrderedDict()
        for raw_text, annots_brackets in get_gold_tuples():
            for annots, brackets in annots_brackets:
                ids, words, tags, heads, deps, ents = annots
                for tag in tags:
                    if tag in orig_tag_map:
                        new_tag_map[tag] = orig_tag_map[tag]
                    else:
                        new_tag_map[tag] = {POS: X}
        cdef Vocab vocab = self.vocab
        if new_tag_map:
            vocab.morphology = Morphology(vocab.strings, new_tag_map,
                                          vocab.morphology.lemmatizer,
                                          exc=vocab.morphology.exc)
        self.cfg["pretrained_vectors"] = kwargs.get("pretrained_vectors")
        if self.model is True:
            for hp in ["token_vector_width", "conv_depth"]:
                if hp in kwargs:
                    self.cfg[hp] = kwargs[hp]
            self.model = self.Model(self.vocab.morphology.n_tags, **self.cfg)
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    @classmethod
    def Model(cls, n_tags, **cfg):
        if cfg.get("pretrained_dims") and not cfg.get("pretrained_vectors"):
            raise ValueError(TempErrors.T008)
        return build_tagger_model(n_tags, **cfg)

    def add_label(self, label, values=None):
        if label in self.labels:
            return 0
        if self.model not in (True, False, None):
            # Here's how the model resizing will work, once the
            # neuron-to-tag mapping is no longer controlled by
            # the Morphology class, which sorts the tag names.
            # The sorting makes adding labels difficult.
            # smaller = self.model._layers[-1]
            # larger = Softmax(len(self.labels)+1, smaller.nI)
            # copy_array(larger.W[:smaller.nO], smaller.W)
            # copy_array(larger.b[:smaller.nO], smaller.b)
            # self.model._layers[-1] = larger
            raise ValueError(TempErrors.T003)
        tag_map = dict(self.vocab.morphology.tag_map)
        if values is None:
            values = {POS: "X"}
        tag_map[label] = values
        self.vocab.morphology = Morphology(
            self.vocab.strings, tag_map=tag_map,
            lemmatizer=self.vocab.morphology.lemmatizer,
            exc=self.vocab.morphology.exc)
        return 1

    def use_params(self, params):
        with self.model.use_params(params):
            yield

    def to_bytes(self, exclude=tuple(), **kwargs):
        serialize = OrderedDict()
        if self.model not in (None, True, False):
            serialize["model"] = self.model.to_bytes
        serialize["vocab"] = self.vocab.to_bytes
        serialize["cfg"] = lambda: srsly.json_dumps(self.cfg)
        tag_map = OrderedDict(sorted(self.vocab.morphology.tag_map.items()))
        serialize["tag_map"] = lambda: srsly.msgpack_dumps(tag_map)
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        return util.to_bytes(serialize, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        def load_model(b):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                token_vector_width = util.env_opt(
                    "token_vector_width",
                    self.cfg.get("token_vector_width", 96))
                self.model = self.Model(self.vocab.morphology.n_tags, **self.cfg)
            self.model.from_bytes(b)

        def load_tag_map(b):
            tag_map = srsly.msgpack_loads(b)
            self.vocab.morphology = Morphology(
                self.vocab.strings, tag_map=tag_map,
                lemmatizer=self.vocab.morphology.lemmatizer,
                exc=self.vocab.morphology.exc)

        deserialize = OrderedDict((
            ("vocab", lambda b: self.vocab.from_bytes(b)),
            ("tag_map", load_tag_map),
            ("cfg", lambda b: self.cfg.update(srsly.json_loads(b))),
            ("model", lambda b: load_model(b)),
        ))
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_bytes(bytes_data, deserialize, exclude)
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        tag_map = OrderedDict(sorted(self.vocab.morphology.tag_map.items()))
        serialize = OrderedDict((
            ("vocab", lambda p: self.vocab.to_disk(p)),
            ("tag_map", lambda p: srsly.write_msgpack(p, tag_map)),
            ("model", lambda p: p.open("wb").write(self.model.to_bytes())),
            ("cfg", lambda p: srsly.write_json(p, self.cfg))
        ))
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        def load_model(p):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                self.model = self.Model(self.vocab.morphology.n_tags, **self.cfg)
            with p.open("rb") as file_:
                self.model.from_bytes(file_.read())

        def load_tag_map(p):
            tag_map = srsly.read_msgpack(p)
            self.vocab.morphology = Morphology(
                self.vocab.strings, tag_map=tag_map,
                lemmatizer=self.vocab.morphology.lemmatizer,
                exc=self.vocab.morphology.exc)

        deserialize = OrderedDict((
            ("cfg", lambda p: self.cfg.update(_load_cfg(p))),
            ("vocab", lambda p: self.vocab.from_disk(p)),
            ("tag_map", load_tag_map),
            ("model", load_model),
        ))
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self


class MultitaskObjective(Tagger):
    """Experimental: Assist training of a parser or tagger, by training a
    side-objective.
    """

    name = "nn_labeller"

    def __init__(self, vocab, model=True, target='dep_tag_offset', **cfg):
        self.vocab = vocab
        self.model = model
        if target == "dep":
            self.make_label = self.make_dep
        elif target == "tag":
            self.make_label = self.make_tag
        elif target == "ent":
            self.make_label = self.make_ent
        elif target == "dep_tag_offset":
            self.make_label = self.make_dep_tag_offset
        elif target == "ent_tag":
            self.make_label = self.make_ent_tag
        elif target == "sent_start":
            self.make_label = self.make_sent_start
        elif hasattr(target, "__call__"):
            self.make_label = target
        else:
            raise ValueError(Errors.E016)
        self.cfg = dict(cfg)
        self.cfg.setdefault("cnn_maxout_pieces", 2)

    @property
    def labels(self):
        return self.cfg.setdefault("labels", {})

    @labels.setter
    def labels(self, value):
        self.cfg["labels"] = value

    def set_annotations(self, docs, dep_ids, tensors=None):
        pass

    def begin_training(self, get_gold_tuples=lambda: [], pipeline=None, tok2vec=None,
                       sgd=None, **kwargs):
        gold_tuples = nonproj.preprocess_training_data(get_gold_tuples())
        for raw_text, annots_brackets in gold_tuples:
            for annots, brackets in annots_brackets:
                ids, words, tags, heads, deps, ents = annots
                for i in range(len(ids)):
                    label = self.make_label(i, words, tags, heads, deps, ents)
                    if label is not None and label not in self.labels:
                        self.labels[label] = len(self.labels)
        if self.model is True:
            token_vector_width = util.env_opt("token_vector_width")
            self.model = self.Model(len(self.labels), tok2vec=tok2vec)
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    @classmethod
    def Model(cls, n_tags, tok2vec=None, **cfg):
        token_vector_width = util.env_opt("token_vector_width", 96)
        softmax = Softmax(n_tags, token_vector_width*2)
        model = chain(
            tok2vec,
            LayerNorm(Maxout(token_vector_width*2, token_vector_width, pieces=3)),
            softmax
        )
        model.tok2vec = tok2vec
        model.softmax = softmax
        return model

    def predict(self, docs):
        self.require_model()
        tokvecs = self.model.tok2vec(docs)
        scores = self.model.softmax(tokvecs)
        return tokvecs, scores

    def get_loss(self, docs, golds, scores):
        if len(docs) != len(golds):
            raise ValueError(Errors.E077.format(value="loss", n_docs=len(docs),
                                                n_golds=len(golds)))
        cdef int idx = 0
        correct = numpy.zeros((scores.shape[0],), dtype="i")
        guesses = scores.argmax(axis=1)
        for i, gold in enumerate(golds):
            for j in range(len(docs[i])):
                # Handes alignment for tokenization differences
                label = self.make_label(j, gold.words, gold.tags,
                                        gold.heads, gold.labels, gold.ents)
                if label is None or label not in self.labels:
                    correct[idx] = guesses[idx]
                else:
                    correct[idx] = self.labels[label]
                idx += 1
        correct = self.model.ops.xp.array(correct, dtype="i")
        d_scores = scores - to_categorical(correct, nb_classes=scores.shape[1])
        loss = (d_scores**2).sum()
        return float(loss), d_scores

    @staticmethod
    def make_dep(i, words, tags, heads, deps, ents):
        if deps[i] is None or heads[i] is None:
            return None
        return deps[i]

    @staticmethod
    def make_tag(i, words, tags, heads, deps, ents):
        return tags[i]

    @staticmethod
    def make_ent(i, words, tags, heads, deps, ents):
        if ents is None:
            return None
        return ents[i]

    @staticmethod
    def make_dep_tag_offset(i, words, tags, heads, deps, ents):
        if deps[i] is None or heads[i] is None:
            return None
        offset = heads[i] - i
        offset = min(offset, 2)
        offset = max(offset, -2)
        return "%s-%s:%d" % (deps[i], tags[i], offset)

    @staticmethod
    def make_ent_tag(i, words, tags, heads, deps, ents):
        if ents is None or ents[i] is None:
            return None
        else:
            return "%s-%s" % (tags[i], ents[i])

    @staticmethod
    def make_sent_start(target, words, tags, heads, deps, ents, cache=True, _cache={}):
        """A multi-task objective for representing sentence boundaries,
        using BILU scheme. (O is impossible)

        The implementation of this method uses an internal cache that relies
        on the identity of the heads array, to avoid requiring a new piece
        of gold data. You can pass cache=False if you know the cache will
        do the wrong thing.
        """
        assert len(words) == len(heads)
        assert target < len(words), (target, len(words))
        if cache:
            if id(heads) in _cache:
                return _cache[id(heads)][target]
            else:
                for key in list(_cache.keys()):
                    _cache.pop(key)
            sent_tags = ["I-SENT"] * len(words)
            _cache[id(heads)] = sent_tags
        else:
            sent_tags = ["I-SENT"] * len(words)

        def _find_root(child):
            seen = set([child])
            while child is not None and heads[child] != child:
                seen.add(child)
                child = heads[child]
            return child

        sentences = {}
        for i in range(len(words)):
            root = _find_root(i)
            if root is None:
                sent_tags[i] = None
            else:
                sentences.setdefault(root, []).append(i)
        for root, span in sorted(sentences.items()):
            if len(span) == 1:
                sent_tags[span[0]] = "U-SENT"
            else:
                sent_tags[span[0]] = "B-SENT"
                sent_tags[span[-1]] = "L-SENT"
        return sent_tags[target]


class ClozeMultitask(Pipe):
    @classmethod
    def Model(cls, vocab, tok2vec, **cfg):
        output_size = vocab.vectors.data.shape[1]
        output_layer = chain(
            LayerNorm(Maxout(output_size, tok2vec.nO, pieces=3)),
            zero_init(Affine(output_size, output_size, drop_factor=0.0))
        )
        model = chain(tok2vec, output_layer)
        model = masked_language_model(vocab, model)
        model.tok2vec = tok2vec
        model.output_layer = output_layer
        return model

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self.cfg = cfg

    def set_annotations(self, docs, dep_ids, tensors=None):
        pass

    def begin_training(self, get_gold_tuples=lambda: [], pipeline=None,
                        tok2vec=None, sgd=None, **kwargs):
        link_vectors_to_models(self.vocab)
        if self.model is True:
            self.model = self.Model(self.vocab, tok2vec)
        X = self.model.ops.allocate((5, self.model.tok2vec.nO))
        self.model.output_layer.begin_training(X)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    def predict(self, docs):
        self.require_model()
        tokvecs = self.model.tok2vec(docs)
        vectors = self.model.output_layer(tokvecs)
        return tokvecs, vectors

    def get_loss(self, docs, vectors, prediction):
        # The simplest way to implement this would be to vstack the
        # token.vector values, but that's a bit inefficient, especially on GPU.
        # Instead we fetch the index into the vectors table for each of our tokens,
        # and look them up all at once. This prevents data copying.
        ids = self.model.ops.flatten([doc.to_array(ID).ravel() for doc in docs])
        target = vectors[ids]
        gradient = (prediction - target) / prediction.shape[0]
        loss = (gradient**2).sum()
        return float(loss), gradient

    def update(self, docs, golds, drop=0., sgd=None, losses=None):
        pass

    def rehearse(self, docs, drop=0., sgd=None, losses=None):
        self.require_model()
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.
        predictions, bp_predictions = self.model.begin_update(docs, drop=drop)
        loss, d_predictions = self.get_loss(docs, self.vocab.vectors.data, predictions)
        bp_predictions(d_predictions, sgd=sgd)

        if losses is not None:
            losses[self.name] += loss


class TextCategorizer(Pipe):
    """Pipeline component for text classification.

    DOCS: https://spacy.io/api/textcategorizer
    """
    name = 'textcat'

    @classmethod
    def Model(cls, nr_class=1, **cfg):
        embed_size = util.env_opt("embed_size", 2000)
        if "token_vector_width" in cfg:
            token_vector_width = cfg["token_vector_width"]
        else:
            token_vector_width = util.env_opt("token_vector_width", 96)
        if cfg.get("architecture") == "simple_cnn":
            tok2vec = Tok2Vec(token_vector_width, embed_size, **cfg)
            return build_simple_cnn_text_classifier(tok2vec, nr_class, **cfg)
        elif cfg.get("architecture") == "bow":
            return build_bow_text_classifier(nr_class, **cfg)
        else:
            return build_text_classifier(nr_class, **cfg)

    @property
    def tok2vec(self):
        if self.model in (None, True, False):
            return None
        else:
            return self.model.tok2vec

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self._rehearsal_model = None
        self.cfg = dict(cfg)

    @property
    def labels(self):
        return tuple(self.cfg.setdefault("labels", []))

    def require_labels(self):
        """Raise an error if the component's model has no labels defined."""
        if not self.labels:
            raise ValueError(Errors.E143.format(name=self.name))

    @labels.setter
    def labels(self, value):
        self.cfg["labels"] = tuple(value)

    def __call__(self, doc):
        scores, tensors = self.predict([doc])
        self.set_annotations([doc], scores, tensors=tensors)
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1):
        for docs in util.minibatch(stream, size=batch_size):
            docs = list(docs)
            scores, tensors = self.predict(docs)
            self.set_annotations(docs, scores, tensors=tensors)
            yield from docs

    def predict(self, docs):
        self.require_model()
        scores = self.model(docs)
        scores = self.model.ops.asarray(scores)
        tensors = [doc.tensor for doc in docs]
        return scores, tensors

    def set_annotations(self, docs, scores, tensors=None):
        for i, doc in enumerate(docs):
            for j, label in enumerate(self.labels):
                doc.cats[label] = float(scores[i, j])

    def update(self, docs, golds, state=None, drop=0., sgd=None, losses=None):
        self.require_model()
        scores, bp_scores = self.model.begin_update(docs, drop=drop)
        loss, d_scores = self.get_loss(docs, golds, scores)
        bp_scores(d_scores, sgd=sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += loss

    def rehearse(self, docs, drop=0., sgd=None, losses=None):
        if self._rehearsal_model is None:
            return
        scores, bp_scores = self.model.begin_update(docs, drop=drop)
        target = self._rehearsal_model(docs)
        gradient = scores - target
        bp_scores(gradient, sgd=sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += (gradient**2).sum()

    def get_loss(self, docs, golds, scores):
        truths = numpy.zeros((len(golds), len(self.labels)), dtype="f")
        not_missing = numpy.ones((len(golds), len(self.labels)), dtype="f")
        for i, gold in enumerate(golds):
            for j, label in enumerate(self.labels):
                if label in gold.cats:
                    truths[i, j] = gold.cats[label]
                else:
                    not_missing[i, j] = 0.
        truths = self.model.ops.asarray(truths)
        not_missing = self.model.ops.asarray(not_missing)
        d_scores = (scores-truths) / scores.shape[0]
        d_scores *= not_missing
        mean_square_error = (d_scores**2).sum(axis=1).mean()
        return float(mean_square_error), d_scores

    def add_label(self, label):
        if label in self.labels:
            return 0
        if self.model not in (None, True, False):
            # This functionality was available previously, but was broken.
            # The problem is that we resize the last layer, but the last layer
            # is actually just an ensemble. We're not resizing the child layers
            # - a huge problem.
            raise ValueError(Errors.E116)
            # smaller = self.model._layers[-1]
            # larger = Affine(len(self.labels)+1, smaller.nI)
            # copy_array(larger.W[:smaller.nO], smaller.W)
            # copy_array(larger.b[:smaller.nO], smaller.b)
            # self.model._layers[-1] = larger
        self.labels = tuple(list(self.labels) + [label])
        return 1

    def begin_training(self, get_gold_tuples=lambda: [], pipeline=None, sgd=None, **kwargs):
        if self.model is True:
            self.cfg["pretrained_vectors"] = kwargs.get("pretrained_vectors")
            self.require_labels()
            self.model = self.Model(len(self.labels), **self.cfg)
            link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd


cdef class DependencyParser(Parser):
    """Pipeline component for dependency parsing.

    DOCS: https://spacy.io/api/dependencyparser
    """

    name = "parser"
    TransitionSystem = ArcEager

    @property
    def postprocesses(self):
        return [nonproj.deprojectivize]

    def add_multitask_objective(self, target):
        if target == "cloze":
            cloze = ClozeMultitask(self.vocab)
            self._multitasks.append(cloze)
        else:
            labeller = MultitaskObjective(self.vocab, target=target)
            self._multitasks.append(labeller)

    def init_multitask_objectives(self, get_gold_tuples, pipeline, sgd=None, **cfg):
        for labeller in self._multitasks:
            tok2vec = self.model.tok2vec
            labeller.begin_training(get_gold_tuples, pipeline=pipeline,
                                    tok2vec=tok2vec, sgd=sgd)

    def __reduce__(self):
        return (DependencyParser, (self.vocab, self.moves, self.model), None, None)

    @property
    def labels(self):
        # Get the labels from the model by looking at the available moves
        return tuple(set(move.split("-")[1] for move in self.move_names))


cdef class EntityRecognizer(Parser):
    """Pipeline component for named entity recognition.

    DOCS: https://spacy.io/api/entityrecognizer
    """

    name = "ner"
    TransitionSystem = BiluoPushDown
    nr_feature = 6

    def add_multitask_objective(self, target):
        if target == "cloze":
            cloze = ClozeMultitask(self.vocab)
            self._multitasks.append(cloze)
        else:
            labeller = MultitaskObjective(self.vocab, target=target)
            self._multitasks.append(labeller)

    def init_multitask_objectives(self, get_gold_tuples, pipeline, sgd=None, **cfg):
        for labeller in self._multitasks:
            tok2vec = self.model.tok2vec
            labeller.begin_training(get_gold_tuples, pipeline=pipeline,
                                    tok2vec=tok2vec)

    def __reduce__(self):
        return (EntityRecognizer, (self.vocab, self.moves, self.model),
                None, None)

    @property
    def labels(self):
        # Get the labels from the model by looking at the available moves, e.g.
        # B-PERSON, I-PERSON, L-PERSON, U-PERSON
        return tuple(set(move.split("-")[1] for move in self.move_names
                if move[0] in ("B", "I", "L", "U")))


class EntityLinker(Pipe):
    """Pipeline component for named entity linking.

    DOCS: TODO
    """
    name = 'entity_linker'
    NIL = "NIL"  # string used to refer to a non-existing link

    @classmethod
    def Model(cls, **cfg):
        embed_width = cfg.get("embed_width", 300)
        hidden_width = cfg.get("hidden_width", 128)
        type_to_int = cfg.get("type_to_int", dict())

        model = build_nel_encoder(embed_width=embed_width, hidden_width=hidden_width, ner_types=len(type_to_int), **cfg)
        return model

    def __init__(self, vocab, **cfg):
        self.vocab = vocab
        self.model = True
        self.kb = None
        self.cfg = dict(cfg)
        self.sgd_context = None
        if not self.cfg.get("context_width"):
            self.cfg["context_width"] = 128

    def set_kb(self, kb):
        self.kb = kb

    def require_model(self):
        # Raise an error if the component's model is not initialized.
        if getattr(self, "model", None) in (None, True, False):
            raise ValueError(Errors.E109.format(name=self.name))

    def require_kb(self):
        # Raise an error if the knowledge base is not initialized.
        if getattr(self, "kb", None) in (None, True, False):
            raise ValueError(Errors.E139.format(name=self.name))

    def begin_training(self, get_gold_tuples=lambda: [], pipeline=None, sgd=None, **kwargs):
        self.require_kb()
        self.cfg["entity_width"] = self.kb.entity_vector_length

        if self.model is True:
            self.model = self.Model(**self.cfg)
            self.sgd_context = self.create_optimizer()

        if sgd is None:
            sgd = self.create_optimizer()

        return sgd

    def update(self, docs, golds, state=None, drop=0.0, sgd=None, losses=None):
        self.require_model()
        self.require_kb()

        if losses is not None:
            losses.setdefault(self.name, 0.0)

        if not docs or not golds:
            return 0

        if len(docs) != len(golds):
            raise ValueError(Errors.E077.format(value="EL training", n_docs=len(docs),
                                                n_golds=len(golds)))

        if isinstance(docs, Doc):
            docs = [docs]
            golds = [golds]

        context_docs = []
        entity_encodings = []

        priors = []
        type_vectors = []

        type_to_int = self.cfg.get("type_to_int", dict())

        for doc, gold in zip(docs, golds):
            ents_by_offset = dict()
            for ent in doc.ents:
                ents_by_offset[str(ent.start_char) + "_" + str(ent.end_char)] = ent
            for entity, kb_dict in gold.links.items():
                start, end = entity
                mention = doc.text[start:end]
                for kb_id, value in kb_dict.items():
                    entity_encoding = self.kb.get_vector(kb_id)
                    prior_prob = self.kb.get_prior_prob(kb_id, mention)

                    gold_ent = ents_by_offset[str(ent.start_char) + "_" + str(ent.end_char)]
                    assert gold_ent is not None
                    type_vector = [0 for i in range(len(type_to_int))]
                    if len(type_to_int) > 0:
                        type_vector[type_to_int[gold_ent.label_]] = 1

                    # store data
                    entity_encodings.append(entity_encoding)
                    context_docs.append(doc)
                    type_vectors.append(type_vector)

                    if self.cfg.get("prior_weight", 1) > 0:
                        priors.append([prior_prob])
                    else:
                        priors.append([0])

        if len(entity_encodings) > 0:
            assert len(priors) == len(entity_encodings) == len(context_docs) == len(type_vectors)

            entity_encodings = self.model.ops.asarray(entity_encodings, dtype="float32")

            context_encodings, bp_context = self.model.tok2vec.begin_update(context_docs, drop=drop)
            mention_encodings = [list(context_encodings[i]) + list(entity_encodings[i]) + priors[i] + type_vectors[i]
                                 for i in range(len(entity_encodings))]
            pred, bp_mention = self.model.begin_update(self.model.ops.asarray(mention_encodings, dtype="float32"), drop=drop)

            loss, d_scores = self.get_loss(scores=pred, golds=golds, docs=docs)
            mention_gradient = bp_mention(d_scores, sgd=sgd)

            context_gradients = [list(x[0:self.cfg.get("context_width")]) for x in mention_gradient]
            bp_context(self.model.ops.asarray(context_gradients, dtype="float32"), sgd=self.sgd_context)

            if losses is not None:
                losses[self.name] += loss
            return loss
        return 0

    def get_loss(self, docs, golds, scores):
        cats = []
        for gold in golds:
            for entity, kb_dict in gold.links.items():
                for kb_id, value in kb_dict.items():
                    cats.append([value])

        cats = self.model.ops.asarray(cats, dtype="float32")
        assert len(scores) == len(cats)

        d_scores = (scores - cats)
        loss = (d_scores ** 2).sum()
        loss = loss / len(cats)
        return loss, d_scores

    def __call__(self, doc):
        kb_ids = self.predict([doc])
        self.set_annotations([doc], kb_ids)
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1):
        for docs in util.minibatch(stream, size=batch_size):
            docs = list(docs)
            kb_ids = self.predict(docs)
            self.set_annotations(docs, kb_ids)
            yield from docs

    def predict(self, docs):
        """ Return the KB IDs for each entity in each doc, including NIL if there is no prediction """
        self.require_model()
        self.require_kb()

        entity_count = 0
        final_kb_ids = []

        if not docs:
            return final_kb_ids

        if isinstance(docs, Doc):
            docs = [docs]

        context_encodings = self.model.tok2vec(docs)
        xp = get_array_module(context_encodings)

        type_to_int = self.cfg.get("type_to_int", dict())

        for i, doc in enumerate(docs):
            if len(doc) > 0:
                context_encoding = context_encodings[i]
                for ent in doc.ents:
                    entity_count += 1
                    type_vector = [0 for i in range(len(type_to_int))]
                    if len(type_to_int) > 0:
                        type_vector[type_to_int[ent.label_]] = 1

                    candidates = self.kb.get_candidates(ent.text)
                    if not candidates:
                        final_kb_ids.append(self.NIL)  # no prediction possible for this entity
                    else:
                        random.shuffle(candidates)

                        # this will set the prior probabilities to 0 (just like in training) if their weight is 0
                        prior_probs = xp.asarray([[c.prior_prob] for c in candidates])
                        prior_probs *= self.cfg.get("prior_weight", 1)
                        scores = prior_probs

                        if self.cfg.get("context_weight", 1) > 0:
                            entity_encodings = xp.asarray([c.entity_vector for c in candidates])
                            assert len(entity_encodings) == len(prior_probs)
                            mention_encodings = [list(context_encoding) + list(entity_encodings[i])
                                                 + list(prior_probs[i]) + type_vector
                                                 for i in range(len(entity_encodings))]
                            scores = self.model(self.model.ops.asarray(mention_encodings, dtype="float32"))

                        # TODO: thresholding
                        best_index = scores.argmax()
                        best_candidate = candidates[best_index]
                        final_kb_ids.append(best_candidate.entity_)

        assert len(final_kb_ids) == entity_count

        return final_kb_ids

    def set_annotations(self, docs, kb_ids, tensors=None):
        i=0
        for doc in docs:
            for ent in doc.ents:
                kb_id = kb_ids[i]
                i += 1
                for token in ent:
                    token.ent_kb_id_ = kb_id

    def to_disk(self, path, exclude=tuple(), **kwargs):
        serialize = OrderedDict()
        serialize["cfg"] = lambda p: srsly.write_json(p, self.cfg)
        serialize["vocab"] = lambda p: self.vocab.to_disk(p)
        serialize["kb"] = lambda p: self.kb.dump(p)
        if self.model not in (None, True, False):
            serialize["model"] = lambda p: p.open("wb").write(self.model.to_bytes())
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        def load_model(p):
             if self.model is True:
                self.model = self.Model(**self.cfg)
             self.model.from_bytes(p.open("rb").read())

        def load_kb(p):
            kb = KnowledgeBase(vocab=self.vocab, entity_vector_length=self.cfg["entity_width"])
            kb.load_bulk(p)
            self.set_kb(kb)

        deserialize = OrderedDict()
        deserialize["cfg"] = lambda p: self.cfg.update(_load_cfg(p))
        deserialize["vocab"] = lambda p: self.vocab.from_disk(p)
        deserialize["kb"] = load_kb
        deserialize["model"] = load_model
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self

    def rehearse(self, docs, sgd=None, losses=None, **config):
        raise NotImplementedError

    def add_label(self, label):
        raise NotImplementedError


class Sentencizer(object):
    """Segment the Doc into sentences using a rule-based strategy.

    DOCS: https://spacy.io/api/sentencizer
    """

    name = "sentencizer"
    default_punct_chars = [".", "!", "?"]

    def __init__(self, punct_chars=None, **kwargs):
        """Initialize the sentencizer.

        punct_chars (list): Punctuation characters to split on. Will be
            serialized with the nlp object.
        RETURNS (Sentencizer): The sentencizer component.

        DOCS: https://spacy.io/api/sentencizer#init
        """
        self.punct_chars = punct_chars or self.default_punct_chars

    def __call__(self, doc):
        """Apply the sentencizer to a Doc and set Token.is_sent_start.

        doc (Doc): The document to process.
        RETURNS (Doc): The processed Doc.

        DOCS: https://spacy.io/api/sentencizer#call
        """
        start = 0
        seen_period = False
        for i, token in enumerate(doc):
            is_in_punct_chars = token.text in self.punct_chars
            token.is_sent_start = i == 0
            if seen_period and not token.is_punct and not is_in_punct_chars:
                doc[start].is_sent_start = True
                start = token.i
                seen_period = False
            elif is_in_punct_chars:
                seen_period = True
        if start < len(doc):
            doc[start].is_sent_start = True
        return doc

    def to_bytes(self, **kwargs):
        """Serialize the sentencizer to a bytestring.

        RETURNS (bytes): The serialized object.

        DOCS: https://spacy.io/api/sentencizer#to_bytes
        """
        return srsly.msgpack_dumps({"punct_chars": self.punct_chars})

    def from_bytes(self, bytes_data, **kwargs):
        """Load the sentencizer from a bytestring.

        bytes_data (bytes): The data to load.
        returns (Sentencizer): The loaded object.

        DOCS: https://spacy.io/api/sentencizer#from_bytes
        """
        cfg = srsly.msgpack_loads(bytes_data)
        self.punct_chars = cfg.get("punct_chars", self.default_punct_chars)
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        """Serialize the sentencizer to disk.

        DOCS: https://spacy.io/api/sentencizer#to_disk
        """
        path = util.ensure_path(path)
        path = path.with_suffix(".json")
        srsly.write_json(path, {"punct_chars": self.punct_chars})


    def from_disk(self, path, exclude=tuple(), **kwargs):
        """Load the sentencizer from disk.

        DOCS: https://spacy.io/api/sentencizer#from_disk
        """
        path = util.ensure_path(path)
        path = path.with_suffix(".json")
        cfg = srsly.read_json(path)
        self.punct_chars = cfg.get("punct_chars", self.default_punct_chars)
        return self


__all__ = ["Tagger", "DependencyParser", "EntityRecognizer", "Tensorizer", "TextCategorizer", "EntityLinker", "Sentencizer"]
