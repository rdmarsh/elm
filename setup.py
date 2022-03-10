from setuptools import setup

setup(
    name='elm',
    version='0.9.5',
    description='Install elm',
    url='https://github.com/rdmarsh/elm',
    author='David Marsh',
    author_email='rdmarsh@gmail.com',
    license='GPL-3.0',
    py_modules=['elm'],
    install_requires=[
        'Click',
    ],
    entry_points={
        'console_scripts': [
            'elm = elm:cli',
        ],
    },
)
