// Tetrix Host docs site. Serves the viewer, a manifest of every markdown
// file under docs/, and the markdown itself. There is no build step: a doc
// added later appears on refresh.
//
//   node tools/docs-site/serve.mjs [port]     (default 4786)
//
// To share it on the tailnet:  tailscale serve --bg --https=<port> <port>
import { createServer } from 'node:http';
import { readFile, readdir } from 'node:fs/promises';
import { join, extname, normalize, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const docsRoot = join(here, '..', '..', 'docs');
const port = Number(process.argv[2] ?? 4786);

// What the server will hand out from docs/: pages and their pictures.
const TYPES = {
	'.md': 'text/markdown; charset=utf-8',
	'.png': 'image/png',
	'.jpg': 'image/jpeg',
	'.svg': 'image/svg+xml',
};

async function walk(dir, prefix = '') {
	const out = [];
	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
		if (entry.isDirectory()) out.push(...(await walk(join(dir, entry.name), rel)));
		else if (entry.name.endsWith('.md')) out.push(rel);
	}
	return out.sort();
}

async function manifest() {
	const entries = await Promise.all(
		(await walk(docsRoot)).map(async (path) => {
			const heading = (await readFile(join(docsRoot, path), 'utf8')).match(/^#\s+(.+)$/m);
			return { path, title: heading ? heading[1].trim() : path };
		}),
	);
	return { entries };
}

const server = createServer(async (req, res) => {
	try {
		const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
		if (path === '/' || path === '/index.html') {
			res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
			res.end(await readFile(join(here, 'index.html')));
		} else if (path === '/manifest.json') {
			res.writeHead(200, { 'content-type': 'application/json' });
			res.end(JSON.stringify(await manifest()));
		} else if (path.startsWith('/docs/')) {
			const rel = normalize(path.slice('/docs/'.length));
			const type = TYPES[extname(rel)];
			if (rel.startsWith('..') || !type) {
				res.writeHead(403).end('forbidden');
				return;
			}
			res.writeHead(200, { 'content-type': type });
			res.end(await readFile(join(docsRoot, rel)));
		} else {
			res.writeHead(404).end('not found');
		}
	} catch (err) {
		res.writeHead(err?.code === 'ENOENT' ? 404 : 500).end(String(err?.message ?? err));
	}
});

server.listen(port, '127.0.0.1', () => {
	console.log(`Tetrix Host docs on http://127.0.0.1:${port}`);
});
