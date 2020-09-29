from typing import Union, Dict, Optional, Any, List, IO, TYPE_CHECKING
from thinc.api import Config, fix_random_seed, set_gpu_allocator
from thinc.api import ConfigValidationError
from pathlib import Path
from wasabi import Printer
import srsly
import numpy
import tarfile
import gzip
import zipfile
import tqdm

from .loop import create_before_to_disk_callback
from ..lookups import Lookups
from ..vectors import Vectors
from ..errors import Errors
from ..schemas import ConfigSchemaTraining, ConfigSchemaPretrain
from ..util import registry, load_model_from_config, resolve_dot_names
from ..util import load_model, ensure_path, OOV_RANK, DEFAULT_OOV_PROB

if TYPE_CHECKING:
    from ..language import Language  # noqa: F401


def init_nlp(config: Config, *, use_gpu: int = -1, silent: bool = True) -> "Language":
    msg = Printer(no_print=silent)
    raw_config = config
    config = raw_config.interpolate()
    if config["training"]["seed"] is not None:
        fix_random_seed(config["training"]["seed"])
    allocator = config["training"]["gpu_allocator"]
    if use_gpu >= 0 and allocator:
        set_gpu_allocator(allocator)
    # Use original config here before it's resolved to functions
    sourced_components = get_sourced_components(config)
    nlp = load_model_from_config(raw_config, auto_fill=True)
    msg.good("Set up nlp object from config")
    config = nlp.config.interpolate()
    # Resolve all training-relevant sections using the filled nlp config
    T = registry.resolve(config["training"], schema=ConfigSchemaTraining)
    dot_names = [T["train_corpus"], T["dev_corpus"]]
    train_corpus, dev_corpus = resolve_dot_names(config, dot_names)
    optimizer = T["optimizer"]
    before_to_disk = create_before_to_disk_callback(T["before_to_disk"])
    # Components that shouldn't be updated during training
    frozen_components = T["frozen_components"]
    # Sourced components that require resume_training
    resume_components = [p for p in sourced_components if p not in frozen_components]
    msg.info(f"Pipeline: {nlp.pipe_names}")
    if resume_components:
        with nlp.select_pipes(enable=resume_components):
            msg.info(f"Resuming training for: {resume_components}")
            nlp.resume_training(sgd=optimizer)
    with nlp.select_pipes(disable=[*frozen_components, *resume_components]):
        nlp.initialize(lambda: train_corpus(nlp), sgd=optimizer)
        msg.good("Initialized pipeline components")
    # Verify the config after calling 'initialize' to ensure labels
    # are properly initialized
    verify_config(nlp)
    nlp = before_to_disk(nlp)
    return nlp


def must_reinitialize(train_config: Config, init_config: Config) -> bool:
    # TODO: do this better and more fine-grained
    return train_config.interpolate().to_str() == init_config.interpolate().to_str()


def init_vocab(
    nlp: "Language",
    *,
    data: Optional[Path] = None,
    lookups: Optional[Lookups] = None,
    vectors: Optional[str] = None,
    silent: bool = True,
) -> "Language":
    msg = Printer(no_print=silent)
    if lookups:
        nlp.vocab.lookups = lookups
        msg.good(f"Added vocab lookups: {', '.join(lookups.tables)}")
    data_path = ensure_path(data)
    if data_path is not None:
        lex_attrs = srsly.read_jsonl(data_path)
        for lexeme in nlp.vocab:
            lexeme.rank = OOV_RANK
        for attrs in lex_attrs:
            if "settings" in attrs:
                continue
            lexeme = nlp.vocab[attrs["orth"]]
            lexeme.set_attrs(**attrs)
        if len(nlp.vocab):
            oov_prob = min(lex.prob for lex in nlp.vocab) - 1
        else:
            oov_prob = DEFAULT_OOV_PROB
        nlp.vocab.cfg.update({"oov_prob": oov_prob})
        msg.good(f"Added {len(nlp.vocab)} lexical entries to the vocab")
    msg.good("Created vocabulary")
    if vectors is not None:
        load_vectors_into_model(nlp, vectors)
        msg.good(f"Added vectors: {vectors}")


def load_vectors_into_model(
    nlp: "Language", name: Union[str, Path], *, add_strings: bool = True
) -> None:
    """Load word vectors from an installed model or path into a model instance."""
    try:
        vectors_nlp = load_model(name)
    except ConfigValidationError as e:
        title = f"Config validation error for vectors {name}"
        desc = (
            "This typically means that there's a problem in the config.cfg included "
            "with the packaged vectors. Make sure that the vectors package you're "
            "loading is compatible with the current version of spaCy."
        )
        err = ConfigValidationError.from_error(config=None, title=title, desc=desc)
        raise err from None
    nlp.vocab.vectors = vectors_nlp.vocab.vectors
    if add_strings:
        # I guess we should add the strings from the vectors_nlp model?
        # E.g. if someone does a similarity query, they might expect the strings.
        for key in nlp.vocab.vectors.key2row:
            if key in vectors_nlp.vocab.strings:
                nlp.vocab.strings.add(vectors_nlp.vocab.strings[key])


def init_tok2vec(
    nlp: "Language", pretrain_config: Dict[str, Any], vocab_config: Dict[str, Any]
) -> bool:
    # Load pretrained tok2vec weights - cf. CLI command 'pretrain'
    P = pretrain_config
    V = vocab_config
    weights_data = None
    init_tok2vec = ensure_path(V["init_tok2vec"])
    if init_tok2vec is not None:
        if P["objective"].get("type") == "vectors" and not V["vectors"]:
            err = 'need initialize.vocab.vectors if pretraining.objective.type is "vectors"'
            errors = [{"loc": ["initialize", "vocab"], "msg": err}]
            raise ConfigValidationError(config=nlp.config, errors=errors)
        if not init_tok2vec.exists():
            err = f"can't find pretrained tok2vec: {init_tok2vec}"
            errors = [{"loc": ["initialize", "vocab", "init_tok2vec"], "msg": err}]
            raise ConfigValidationError(config=nlp.config, errors=errors)
        with init_tok2vec.open("rb") as file_:
            weights_data = file_.read()
    if weights_data is not None:
        tok2vec_component = P["component"]
        if tok2vec_component is None:
            desc = (
                f"To use pretrained tok2vec weights, [pretraining.component] "
                f"needs to specify the component that should load them."
            )
            err = "component can't be null"
            errors = [{"loc": ["pretraining", "component"], "msg": err}]
            raise ConfigValidationError(
                config=nlp.config["pretraining"], errors=errors, desc=desc
            )
        layer = nlp.get_pipe(tok2vec_component).model
        if P["layer"]:
            layer = layer.get_ref(P["layer"])
        layer.from_bytes(weights_data)
        return True
    return False


def verify_config(nlp: "Language") -> None:
    """Perform additional checks based on the config, loaded nlp object and training data."""
    # TODO: maybe we should validate based on the actual components, the list
    # in config["nlp"]["pipeline"] instead?
    for pipe_config in nlp.config["components"].values():
        # We can't assume that the component name == the factory
        factory = pipe_config["factory"]
        if factory == "textcat":
            verify_textcat_config(nlp, pipe_config)


def verify_textcat_config(nlp: "Language", pipe_config: Dict[str, Any]) -> None:
    # if 'positive_label' is provided: double check whether it's in the data and
    # the task is binary
    if pipe_config.get("positive_label"):
        textcat_labels = nlp.get_pipe("textcat").labels
        pos_label = pipe_config.get("positive_label")
        if pos_label not in textcat_labels:
            raise ValueError(
                Errors.E920.format(pos_label=pos_label, labels=textcat_labels)
            )
        if len(list(textcat_labels)) != 2:
            raise ValueError(
                Errors.E919.format(pos_label=pos_label, labels=textcat_labels)
            )


def get_sourced_components(config: Union[Dict[str, Any], Config]) -> List[str]:
    """RETURNS (List[str]): All sourced components in the original config,
        e.g. {"source": "en_core_web_sm"}. If the config contains a key
        "factory", we assume it refers to a component factory.
    """
    return [
        name
        for name, cfg in config.get("components", {}).items()
        if "factory" not in cfg and "source" in cfg
    ]


def convert_vectors(
    nlp: "Language",
    vectors_loc: Optional[Path],
    *,
    truncate: int,
    prune: int,
    name: Optional[str] = None,
    silent: bool = True,
) -> None:
    msg = Printer(no_print=silent)
    vectors_loc = ensure_path(vectors_loc)
    if vectors_loc and vectors_loc.parts[-1].endswith(".npz"):
        nlp.vocab.vectors = Vectors(data=numpy.load(vectors_loc.open("rb")))
        for lex in nlp.vocab:
            if lex.rank and lex.rank != OOV_RANK:
                nlp.vocab.vectors.add(lex.orth, row=lex.rank)
    else:
        if vectors_loc:
            with msg.loading(f"Reading vectors from {vectors_loc}"):
                vectors_data, vector_keys = read_vectors(vectors_loc, truncate)
            msg.good(f"Loaded vectors from {vectors_loc}")
        else:
            vectors_data, vector_keys = (None, None)
        if vector_keys is not None:
            for word in vector_keys:
                if word not in nlp.vocab:
                    nlp.vocab[word]
        if vectors_data is not None:
            nlp.vocab.vectors = Vectors(data=vectors_data, keys=vector_keys)
    if name is None:
        # TODO: Is this correct? Does this matter?
        nlp.vocab.vectors.name = f"{nlp.meta['lang']}_{nlp.meta['name']}.vectors"
    else:
        nlp.vocab.vectors.name = name
    nlp.meta["vectors"]["name"] = nlp.vocab.vectors.name
    if prune >= 1:
        nlp.vocab.prune_vectors(prune)
    msg.good(f"Successfully converted {len(nlp.vocab.vectors)} vectors")


def read_vectors(vectors_loc: Path, truncate_vectors: int):
    f = open_file(vectors_loc)
    f = ensure_shape(f)
    shape = tuple(int(size) for size in next(f).split())
    if truncate_vectors >= 1:
        shape = (truncate_vectors, shape[1])
    vectors_data = numpy.zeros(shape=shape, dtype="f")
    vectors_keys = []
    for i, line in enumerate(tqdm.tqdm(f)):
        line = line.rstrip()
        pieces = line.rsplit(" ", vectors_data.shape[1])
        word = pieces.pop(0)
        if len(pieces) != vectors_data.shape[1]:
            raise ValueError(Errors.E094.format(line_num=i, loc=vectors_loc))
        vectors_data[i] = numpy.asarray(pieces, dtype="f")
        vectors_keys.append(word)
        if i == truncate_vectors - 1:
            break
    return vectors_data, vectors_keys


def open_file(loc: Union[str, Path]) -> IO:
    """Handle .gz, .tar.gz or unzipped files"""
    loc = ensure_path(loc)
    if tarfile.is_tarfile(str(loc)):
        return tarfile.open(str(loc), "r:gz")
    elif loc.parts[-1].endswith("gz"):
        return (line.decode("utf8") for line in gzip.open(str(loc), "r"))
    elif loc.parts[-1].endswith("zip"):
        zip_file = zipfile.ZipFile(str(loc))
        names = zip_file.namelist()
        file_ = zip_file.open(names[0])
        return (line.decode("utf8") for line in file_)
    else:
        return loc.open("r", encoding="utf8")


def ensure_shape(lines):
    """Ensure that the first line of the data is the vectors shape.
    If it's not, we read in the data and output the shape as the first result,
    so that the reader doesn't have to deal with the problem.
    """
    first_line = next(lines)
    try:
        shape = tuple(int(size) for size in first_line.split())
    except ValueError:
        shape = None
    if shape is not None:
        # All good, give the data
        yield first_line
        yield from lines
    else:
        # Figure out the shape, make it the first value, and then give the
        # rest of the data.
        width = len(first_line.split()) - 1
        captured = [first_line] + list(lines)
        length = len(captured)
        yield f"{length} {width}"
        yield from captured
