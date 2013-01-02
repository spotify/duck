import dbm
import json
import contextlib

DEFAULT_DB = "/var/duck"
DEFAULT_ENCODING = 'utf-8'


class DBSession(object):
    def __init__(self, db, encoding):
        self._db = db
        self._encoding = encoding

    def get(self, key, default=None):
        try:
            value = self._db[key]
        except KeyError:
            return default

        if value is None:
            return None

        value = value.decode(self._encoding)
        value = json.loads(value)
        return value

    def set(self, key, value):
        value = json.dumps(value)
        value = value.encode(self._encoding)
        self._db[key] = value

    def keys(self):
        return self._db.keys()


class DB(object):
    def __init__(self, path=None, encoding=None):
        if path is None:
            path = DEFAULT_DB
        if encoding is None:
            encoding = DEFAULT_ENCODING
        self._full_path = "{0}.dbm".format(path)
        self._encoding = encoding

    @contextlib.contextmanager
    def open(self):
        with contextlib.closing(dbm.open(self._full_path, "c")) as db:
            yield DBSession(db, self._encoding)
