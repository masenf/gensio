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
skip_shared_object_link_check_patch = here / "swig" / "python" / "patch--m4--ax_python_devel.m4.patch"


class build_ext(_build_ext.build_ext):
    """
    Build extension using GNU Autotools.

    Re-use the package's existing build system, while bundling compiled
    libraries into the python package.
    """
    def patch_rpath(self, lib):
        copy_file(str(lib), self.build_lib)
        # re-home the runpath to allow --user installation from sdist
        spawn(
            [
                "patchelf",
                "--set-rpath",
                # this doesn't work with auditwheel, only sdist
                #"{}:{}".format(sysconfig.get_path("platlib"), self.build_lib),
                "$ORIGIN",  # XXX: security implications
                str(Path(self.build_lib) / lib.name),
            ]
        )

    def run(self):
        if not self.extensions:
            return
        os.environ["PYTHON_VERSION"] = sysconfig.get_python_version()
        configure = here / "configure"
        if not configure.exists():
            spawn([str(here / "reconf")])
        spawn(
            [
                str(configure),
                "--with-python",
                # normally this would be automatic... but explicitly override it
                # to avoid the `-lpythonX.Y` flag, which isn't supported by manylinux
                "PYTHON_LIBS={}".format(sysconfig.get_config_var("LIBDIR")),
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
                    self.patch_rpath(lib)


setup(
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
