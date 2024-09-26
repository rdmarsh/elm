from setuptools import setup

with open('README.md', 'r', encoding='utf-8') as fh:
    long_description = fh.read()

setup(
    name='elm',
    version='1.2.4',
    description='Install elm',
    long_description=long_description,
    long_description_content_type='text/markdown',
    url='https://github.com/rdmarsh/elm',
    author='David Marsh',
    author_email='rdmarsh@gmail.com',
    license='GPLv3',
    py_modules=['elm'],
    install_requires=[
        'Click>=7.0,<9.0',  # Pinning version range
    ],
    entry_points={
        'console_scripts': [
            'elm=elm:cli',
        ],
    },
    classifiers=[
        'Programming Language :: Python :: 3',
        'License :: OSI Approved :: GNU General Public License v3 (GPLv3)',
        'Operating System :: OS Independent',
        ],
    python_requires='>=3.6',  # Define minimum Python version
)
