import { loadConfig } from './config.js';
import { createPool, migrate } from './db.js';

const db = createPool(loadConfig().databaseUrl);
const applied = await migrate(db);
console.log(applied.length ? `已执行：${applied.join(', ')}` : '数据库已是最新');
await db.end();
