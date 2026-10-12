import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;
const HOST = '0.0.0.0';

// Serve static assets and docs from /docs directory
app.use(express.static(path.join(__dirname, 'docs')));

// Also serve the repository files if requested
app.use('/raw', express.static(__dirname));

// Fallback to docs/index.html for any SPA/HTML route
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'docs', 'index.html'));
});

app.listen(PORT, HOST, () => {
  console.log(`Halo CE docs server running at http://${HOST}:${PORT}`);
});
