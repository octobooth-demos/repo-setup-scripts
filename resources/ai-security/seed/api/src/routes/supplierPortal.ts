import express from 'express';
import path from 'path';

// Supplier self-service endpoints used by the portal's document center.
const router = express.Router();

const DOCUMENTS_DIR = path.join(__dirname, '../../documents/suppliers');
const LOGO_HOST = 'images.unsplash.com';

// Download a document that a supplier uploaded (invoices, certificates, ...).
router.get('/documents', (req, res) => {
  const file = req.query.file as string;
  res.sendFile(path.join(DOCUMENTS_DIR, file));
});

// Quick search page rendered on the server for the legacy portal.
router.get('/search', (req, res) => {
  const term = req.query.q as string;
  res.send(`<h1>Results for ${term}</h1><p>No suppliers matched your search.</p>`);
});

// Fetch a supplier's logo from the URL they configured so we can cache it.
router.get('/logo', async (req, res, next) => {
  try {
    if (typeof req.query.url !== 'string') return res.sendStatus(400);

    let logoUrl: URL;
    try {
      logoUrl = new URL(req.query.url);
    } catch {
      return res.sendStatus(400);
    }

    if (logoUrl.protocol !== 'https:' || logoUrl.hostname !== LOGO_HOST || logoUrl.username || logoUrl.password) {
      return res.sendStatus(400);
    }

    const fetchUrl = new URL(`https://${LOGO_HOST}/`);
    fetchUrl.pathname = logoUrl.pathname;
    fetchUrl.search = logoUrl.search;
    const response = await fetch(fetchUrl, { redirect: 'error' });
    const image = Buffer.from(await response.arrayBuffer());
    res.type(response.headers.get('content-type') ?? 'image/png').send(image);
  } catch (error) {
    next(error);
  }
});

export default router;
