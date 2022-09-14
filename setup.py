"""
PyPI / manylinux compatible sdist + bdist_wheel package.

Buildable without additional packages in the
quay.io/pypa/manylinux2014_x86_64 docker image
"""
from contextlib import contextmanager
import errno
import os
from pathlib import Path
import sysconfig

from setuptools import setup, Extension, find_packages
from distutils.command import build_ext as _build_ext
from distutils.dir_util import mkpath
from distutils.errors import DistutilsExecError
from distutils.file_util import copy_file
from distutils.spawn import spawn


here = Path( __file__ ).parent.absolute()
gensio_lib_output = here / "lib" / ".libs"
gensio_swig_output = here / "swig" / "python" / ".libs"
readme = long_description = (here / "README.rst").read_text()


class build_ext(_build_ext.build_ext):
    """
    Build extension using GNU Autotools.

    Re-use the package's existing build system, while bundling compiled
    libraries into the python package.
    """

    def run(self):
        if not self.extensions:
            return
        os.environ["PYTHON_VERSION"] = sysconfig.get_python_version()
        configure = here / "configure"
        if not configure.exists():
            spawn([str(here / "reconf")])

        config_args = []
        if "linux" in sysconfig.get_config_var("SOABI"):
            # normally this would be automatic... but explicitly override it
            # to avoid the `-lpythonX.Y` flag, which isn't supported by manylinux
            config_args.append("PYTHON_LIBS={}".format(sysconfig.get_config_var("LIBDIR")))

        spawn(
            [
                str(configure),
                "--with-python",
                *config_args,
            ],
        )
        try:
            # remake the python module only, if possible
            spawn(["make", "-C", str(here / "swig" / "python")])
        except DistutilsExecError:
            # make the whole package
            spawn(["make", "-C", str(here)])
        mkpath(self.build_lib)
        for ext in self.extensions:
            for lib_dir in ext.depends or []:
                for lib in lib_dir.glob("*.so*"):
                    # TODO: avoid copying symlinks
                    copy_file(str(lib), self.build_lib)


setup(
    name='gensio',
    use_scm_version=True,
    url='https://github.com/cminyard/gensio',
    author='Corey Minyard',
    author_email='cminyard@mvista.com',
    description='a framework for giving a consistent view of various stream (and packet) I/O types',
    long_description=readme,
    long_description_content_type="text/x-rst",
    py_modules=["gensio"],
    package_dir={'': "swig/python"},
    cmdclass={'build_ext': build_ext},
    ext_modules=[
        Extension(
            name="gensio",
            sources=[],  # overridden in build_ext
            depends=[gensio_swig_output, gensio_lib_output],
        ),
    ],
)
