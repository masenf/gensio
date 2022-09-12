"""
PyPI / manylinux compatible sdist + bdist_wheel package.

Buildable without additional packages in the
quay.io/pypa/manylinux2014_x86_64 docker image
"""
from contextlib import contextmanager
import errno
import os
from pathlib import Path
import subprocess
import sysconfig

from setuptools import setup, Extension, find_packages
from distutils.command import build_ext as _build_ext
from distutils.dir_util import mkpath
from distutils.errors import DistutilsExecError
from distutils.file_util import copy_file
from distutils.spawn import spawn


here = Path(__file__).parent.absolute()
gensio_lib_output = here / "lib" / ".libs"
gensio_swig_output = here / "swig" / "python" / ".libs"
readme = long_description = (here / "README.rst").read_text()


class build_ext(_build_ext.build_ext):
    """
    Build extension using GNU Autotools.

    Re-use the package's existing build system, while bundling compiled
    libraries into the python package.
    """

    def macos_rpath(self, lib):
        """
        Fix 'rpath' for osx.

        Requires developer command line tools.

        Similar in principal to delocate, but for some reason, delocate cannot
        find the libs to repair the wheel without installation into the
        system. TODO.

        (alternate approach would be to just install the lib, then delocate).
        """
        relative_lib_names = [l.name for l in Path(self.build_lib).iterdir()]
        links = subprocess.check_output(["otool", "-L", str(lib)], encoding="utf-8")
        for line in links.splitlines():
            if not line or not line.startswith("\t"):
                continue
            dep_lib = Path(line.strip().partition(" (")[0])
            if dep_lib.name in relative_lib_names:
                spawn(
                    [
                        "install_name_tool",
                        "-change",
                        str(dep_lib),
                        "@loader_path/{}".format(dep_lib.name),
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

        config_args = []
        platform_lib_globs = []
        lib_callbacks = []
        if "linux" in sysconfig.get_config_var("SOABI"):
            # normally this would be automatic... but explicitly override it
            # to avoid the `-lpythonX.Y` flag, which isn't supported by manylinux
            config_args.append(
                "PYTHON_LIBS={}".format(sysconfig.get_config_var("LIBDIR"))
            )
            platform_lib_globs.append("*.so*")
        elif "darwin" in sysconfig.get_config_var("MULTIARCH"):
            platform_lib_globs.append("*.so*")
            platform_lib_globs.append("*.dylib*")
            lib_callbacks.append(self.macos_rpath)
        elif "win" in sysconfig.get_config_var("MULTIARCH"):
            platform_lib_globs.append("*")

        spawn(
            [
                str(configure),
                "--with-go=no",
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
                for lib_glob in platform_lib_globs:
                    for lib in lib_dir.glob(lib_glob):
                        # TODO: avoid copying symlinks
                        copy_file(str(lib), self.build_lib)
            for lib_dir in ext.depends or []:
                for lib_glob in platform_lib_globs:
                    for lib in lib_dir.glob(lib_glob):
                        for cb in lib_callbacks:
                            cb(lib)


setup(
    name="gensio-binary",
    use_scm_version=True,
    url="https://github.com/masenf/gensio",
    author="Corey Minyard",
    author_email="cminyard@mvista.com",
    maintainer="Masen Furer",
    maintainer_email="m_github@0x26.net",
    description="a framework for giving a consistent view of various stream (and packet) I/O types",
    long_description=readme,
    long_description_content_type="text/x-rst",
    py_modules=["gensio"],
    package_dir={"": "swig/python"},
    cmdclass={"build_ext": build_ext},
    ext_modules=[
        Extension(
            name="gensio",
            sources=[],  # overridden in build_ext
            depends=[gensio_swig_output, gensio_lib_output],
        ),
    ],
)
