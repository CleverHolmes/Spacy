#!/usr/bin/env python
from __future__ import print_function
import os
import shutil
import subprocess
import sys
import contextlib
from distutils.command.build_ext import build_ext
from distutils.sysconfig import get_python_inc

try:
    from setuptools import Extension, setup
except ImportError:
    from distutils.core import Extension, setup


PACKAGES = [
    'spacy',
    'spacy.tokens',
    'spacy.en',
    'spacy.serialize',
    'spacy.syntax',
    'spacy.munge',
    'spacy.tests',
    'spacy.tests.matcher',
    'spacy.tests.morphology',
    'spacy.tests.munge',
    'spacy.tests.parser',
    'spacy.tests.serialize',
    'spacy.tests.spans',
    'spacy.tests.tagger',
    'spacy.tests.tokenizer',
    'spacy.tests.tokens',
    'spacy.tests.vectors',
    'spacy.tests.vocab']


MOD_NAMES = [
    'spacy.parts_of_speech',
    'spacy.strings',
    'spacy.lexeme',
    'spacy.vocab',
    'spacy.attrs',
    'spacy.morphology',
    'spacy.tagger',
    'spacy.syntax.stateclass',
    'spacy.syntax._state',
    'spacy.tokenizer',
    'spacy.syntax.parser',
    'spacy.syntax.transition_system',
    'spacy.syntax.arc_eager',
    'spacy.syntax._parse_features',
    'spacy.gold',
    'spacy.orth',
    'spacy.tokens.doc',
    'spacy.tokens.span',
    'spacy.tokens.token',
    'spacy.serialize.packer',
    'spacy.serialize.huffman',
    'spacy.serialize.bits',
    'spacy.cfile',
    'spacy.matcher',
    'spacy.syntax.ner',
    'spacy.symbols']


if sys.version_info[:2] < (2, 7) or (3, 0) <= sys.version_info[0:2] < (3, 4):
    raise RuntimeError('Python version 2.7 or >= 3.4 required.')


# By subclassing build_extensions we have the actual compiler that will be used
# which is really known only after finalize_options
# http://stackoverflow.com/questions/724664/python-distutils-how-to-get-a-compiler-that-is-going-to-be-used
compile_options =  {
    'msvc': ['/Ox', '/EHsc'],
    'mingw32' : ['-O3', '-Wno-strict-prototypes', '-Wno-unused-function'],
    'other' : ['-O3', '-Wno-strict-prototypes', '-Wno-unused-function']
}


link_options = {
    'msvc' : [],
    'mingw32': [],
    'other' : []
}


if not sys.platform.startswith('darwin'):
    compile_options['other'].append('-fopenmp')
    link_options['other'].append('-fopenmp')


class build_ext_options:
    def build_options(self):
        for e in self.extensions:
            e.extra_compile_args = compile_options.get(
                self.compiler.compiler_type, compile_options['other'])
        for e in self.extensions:
            e.extra_link_args = link_options.get(
                self.compiler.compiler_type, link_options['other'])


class build_ext_subclass(build_ext, build_ext_options):
    def build_extensions(self):
        build_ext_options.build_options(self)
        build_ext.build_extensions(self)


def generate_cython(root, source):
    print('Cythonizing sources')
    p = subprocess.call([sys.executable,
                         os.path.join(root, 'bin', 'cythonize.py'),
                         source])
    if p != 0:
        raise RuntimeError('Running cythonize failed')


def is_source_release(path):
    return os.path.exists(os.path.join(path, 'PKG-INFO'))


def clean(path):
    for name in MOD_NAMES:
        name = name.replace('.', '/')
        for ext in ['.so', '.html', '.cpp', '.c']:
            file_path = os.path.join(path, name + ext)
            if os.path.exists(file_path):
                os.unlink(file_path)


@contextlib.contextmanager
def chdir(new_dir):
    old_dir = os.getcwd()
    try:
        os.chdir(new_dir)
        sys.path.insert(0, new_dir)
        yield
    finally:
        del sys.path[0]
        os.chdir(old_dir)


def setup_package():
    root = os.path.abspath(os.path.dirname(__file__))

    if len(sys.argv) > 1 and sys.argv[1] == 'clean':
        return clean(root)

    with chdir(root):
        about = {}
        with open(os.path.join(root, "spacy", "about.py")) as f:
            exec(f.read(), about)

        include_dirs = [
            get_python_inc(plat_specific=True),
            os.path.join(root, 'include')]

        ext_modules = []
        for mod_name in MOD_NAMES:
            mod_path = mod_name.replace('.', '/') + '.cpp'
            ext_modules.append(
                Extension(mod_name, [mod_path],
                    language='c++', include_dirs=include_dirs))

        if not is_source_release(root):
            generate_cython(root, 'spacy')

        setup(
            name=about['__name__'],
            zip_safe=False,
            packages=PACKAGES,
            package_data={'': ['*.pyx', '*.pxd']},
            description=about['__summary__'],
            author=about['__author__'],
            author_email=about['__email__'],
            version=about['__version__'],
            url=about['__uri__'],
            license=about['__license__'],
            ext_modules=ext_modules,
            install_requires=['numpy', 'murmurhash>=0.26,<0.27', 'cymem>=1.30,<1.32.0', 'preshed>=0.46.1,<0.47',
                              'thinc>=5.0.0,<5.1.0', 'text_unidecode', 'plac', 'six',
                              'ujson', 'cloudpickle', 'sputnik>=0.8.0,<0.9.0'],
            cmdclass = {
                'build_ext': build_ext_subclass},
        )


if __name__ == '__main__':
    setup_package()
