from setuptools import setup, find_packages

with open('README.md', 'r', encoding='utf-8') as fh:
    long_description = fh.read()

from _version import __version__

setup(
    name='elm',
    version=__version__,
    description='A CLI interface for extracting LogicMonitor data via the API',
    long_description=long_description,
    long_description_content_type='text/markdown',
    url='https://github.com/rdmarsh/elm',
    author='David Marsh',
    author_email='rdmarsh@gmail.com',
    license='GPLv3',
    packages=find_packages(),  # Automatically includes _cmds and other packages
    include_package_data=True, # Include non-Python files like templates
    install_requires=[
        'click_config_file~=0.6.0',
        'click~=7.1.2',
        'htmlmin2~=0.1.13',
        'Jinja2~=3.1.2',
        'jinja2-cli~=0.8.2',
        'lxml~=5.2.1',
        'packaging~=23.2',
        'pandas~=2.3',
        'Pygments~=2.15.0',
        'PySocks~=1.7.1',
        'requests~=2.32.0',
        'tabulate~=0.8.10',
    ],
    entry_points={
        'console_scripts': [
            'elm=elm:cli',  # Points to your cli() function in elm.py
        ],
    },
    classifiers=[
        'Programming Language :: Python :: 3',
        'License :: OSI Approved :: GNU General Public License v3 (GPLv3)',
        'Operating System :: OS Independent',
    ],
    python_requires='>=3.6',
)
