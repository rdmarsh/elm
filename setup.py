from setuptools import setup

setup(
    name='elm',
    version='0.9',
    description='Install elm',
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
