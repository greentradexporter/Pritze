const assert = require('node:assert/strict');
function memoryFirestore(initial) {
  const rows = new Map(Object.entries(initial));
  const document = (path) => ({path, id: path.split('/').at(-1), get: async () => snapshot(path)});
  const snapshot = (path) => ({ref: document(path), exists: rows.has(path), data: () => rows.get(path)});
  const collection = (name, filters = [], count = Infinity) => ({
    doc: (id) => document(`${name}/${id}`),
    where: (key, op, value) => {assert.equal(op, '=='); return collection(name, [...filters, [key, value]], count);},
    limit: (limit) => collection(name, filters, limit),
    get: async () => {
      const docs = [...rows.keys()].filter((path) => path.startsWith(`${name}/`) &&
        filters.every(([key, value]) => rows.get(path)[key] === value)).slice(0, count).map(snapshot);
      return {docs, size: docs.length, empty: docs.length === 0};
    },
  });
  const firestore = {collection, runTransaction: async (callback) => {
    const writes = [];
    const result = await callback({
      get: async (ref) => {assert.equal(writes.length, 0, 'all reads must precede writes'); return ref.get();},
      update: (ref, data) => writes.push([ref.path, data]),
      set: (ref, data) => writes.push([ref.path, data]),
    });
    for (const [path, data] of writes) rows.set(path, {...rows.get(path), ...data});
    return result;
  }};
  return {rows, firestore};
}
module.exports = {memoryFirestore};
