import sqlite3, datetime, os

db_path = 'chithram.db'
conn = sqlite3.connect(db_path)

size = os.path.getsize('./models/semantic-search.onnx')
version = datetime.datetime.now().strftime('%Y%m%d%H%M%S')

conn.execute(
    'UPDATE model_metadata SET version=?, size=?, updated_at=? WHERE name=?',
    (version, size, datetime.datetime.now().isoformat(), 'semantic-search')
)
conn.commit()

rows = conn.execute('SELECT name, version, size FROM model_metadata WHERE name="semantic-search"').fetchall()
print('Updated:', rows)
conn.close()
