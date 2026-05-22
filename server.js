#!/usr/bin/env node

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');
const path = require('path');
const fs = require('fs').promises;
const chalk = require('chalk');

const ChannelManager = require('./lib/channelManager');
const M3UParser = require('./lib/m3uParser');
const { sanitizeChannelName } = require('./lib/utils');
const config = require('./config.json');

const app = express();
const channelManager = new ChannelManager(config);
const m3uParser = new M3UParser();

app.use(helmet({
    contentSecurityPolicy: false,
    crossOriginEmbedderPolicy: false
}));
app.use(cors());
app.use(compression());
app.use(morgan('combined'));
app.use(express.json({ limit: '50mb' }));
app.use(express.static('public'));

// ============ HEALTH ============

app.get('/health', (req, res) => {
    res.json({
        status: 'OK',
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        channels: channelManager.getChannelCount()
    });
});

// ============ HLS DELIVERY ============

function safeResolve(base, ...paths) {
    const resolved = path.resolve(path.join(base, ...paths));
    const baseResolved = path.resolve(base);
    if (!resolved.startsWith(baseResolved + path.sep) && resolved !== baseResolved) {
        return null;
    }
    return resolved;
}

app.get('/hls/:channel/*.m3u8', async (req, res) => {
    const { channel } = req.params;
    if (!channel || channel.includes('..') || channel.includes('/') || channel.includes('\\')) {
        return res.status(400).json({ error: 'Invalid channel name' });
    }
    const filename = req.params[0] + '.m3u8';
    const filePath = safeResolve(config.hls.segmentPath, channel, filename);
    if (!filePath) return res.status(403).json({ error: 'Forbidden' });

    try {
        const content = await fs.readFile(filePath, 'utf-8');
        res.set({
            'Content-Type': 'application/vnd.apple.mpegurl',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Pragma': 'no-cache',
            'Expires': '0',
            'Access-Control-Allow-Origin': '*'
        });
        res.send(content);
    } catch (error) {
        res.status(404).json({ error: 'Playlist not found' });
    }
});

app.get('/hls/:channel/*.ts', async (req, res) => {
    const { channel } = req.params;
    if (!channel || channel.includes('..') || channel.includes('/') || channel.includes('\\')) {
        return res.status(400).json({ error: 'Invalid channel name' });
    }
    const filename = req.params[0] + '.ts';
    const filePath = safeResolve(config.hls.segmentPath, channel, filename);
    if (!filePath) return res.status(403).json({ error: 'Forbidden' });

    try {
        const stat = await fs.stat(filePath);
        const stream = require('fs').createReadStream(filePath);
        res.set({
            'Content-Type': 'video/mp2t',
            'Content-Length': stat.size,
            'Cache-Control': 'public, max-age=10',
            'Access-Control-Allow-Origin': '*'
        });
        stream.on('error', () => {
            if (!res.headersSent) res.status(500).end();
            res.destroy();
        });
        stream.pipe(res);
    } catch (error) {
        res.status(404).json({ error: 'Segment not found' });
    }
});

// ============ CHANNEL CRUD ============

app.get('/api/channels', async (req, res) => {
    try {
        const channels = await channelManager.getAllChannels();
        res.json({ success: true, count: channels.length, channels });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.get('/api/channels/:name', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    try {
        const channel = await channelManager.getChannel(name);
        if (!channel) {
            return res.status(404).json({ success: false, error: 'Channel not found' });
        }
        res.json({ success: true, channel });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels', async (req, res) => {
    const name = sanitizeChannelName(req.body.name);
    const { source, bitrate = 5000, group, logo, tvgId, tvgName, tvgLogo, autoRestart } = req.body;

    if (!name || !source) {
        return res.status(400).json({ success: false, error: 'Name and source URL required' });
    }

    try {
        const result = await channelManager.addChannel(name, source, bitrate, {
            autoRestart, group, logo, tvgId, tvgName, tvgLogo
        });

        res.json({
            success: true,
            message: `Channel '${name}' created`,
            channel: result,
            playback_url: `${getBaseUrl(req)}/hls/${name}/index.m3u8`
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.put('/api/channels/:name', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    const { source, bitrate, autoRestart, group, logo, tvgId, tvgName, tvgLogo } = req.body;

    try {
        const result = await channelManager.updateChannel(name, {
            source, bitrate, autoRestart, group, logo, tvgId, tvgName, tvgLogo
        });

        res.json({
            success: true,
            message: `Channel '${name}' updated`,
            channel: result
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.delete('/api/channels/:name', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    try {
        await channelManager.removeChannel(name);
        res.json({ success: true, message: `Channel '${name}' deleted` });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// ============ M3U IMPORT (MUST BE BEFORE :name ROUTES) ============

app.post('/api/channels/import-m3u', async (req, res) => {
    const { url } = req.body;

    if (!url) {
        return res.status(400).json({ success: false, error: 'M3U URL required' });
    }

    try {
        const channels = await m3uParser.fetchAndParse(url);
        res.json({
            success: true,
            count: channels.length,
            channels: channels.map((ch, i) => ({
                ...ch,
                id: i,
                selected: true
            }))
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// ============ BATCH OPERATIONS (MUST BE BEFORE :name ROUTES) ============

app.post('/api/channels/batch/add', async (req, res) => {
    const { channels } = req.body;

    if (!channels || !Array.isArray(channels) || channels.length === 0) {
        return res.status(400).json({ success: false, error: 'Channels array required' });
    }

    try {
        const result = await channelManager.addChannelsBatch(channels);
        res.json({
            success: true,
            message: `Added ${result.added.length} channel(s), ${result.failed.length} failed`,
            ...result
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels/batch/delete', async (req, res) => {
    const { names } = req.body;

    if (!names || !Array.isArray(names) || names.length === 0) {
        return res.status(400).json({ success: false, error: 'Names array required' });
    }

    try {
        const result = await channelManager.removeChannelsBatch(names);
        res.json({
            success: true,
            message: `Removed ${result.removed.length} channel(s)`,
            ...result
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels/batch/restart', async (req, res) => {
    const { names } = req.body;

    if (!names || !Array.isArray(names) || names.length === 0) {
        return res.status(400).json({ success: false, error: 'Names array required' });
    }

    try {
        const result = await channelManager.restartChannelsBatch(names);
        res.json({
            success: true,
            message: `Restarted ${result.restarted.length} channel(s)`,
            ...result
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels/batch/stop', async (req, res) => {
    const { names } = req.body;

    if (!names || !Array.isArray(names) || names.length === 0) {
        return res.status(400).json({ success: false, error: 'Names array required' });
    }

    try {
        const result = await channelManager.stopChannelsBatch(names);
        res.json({
            success: true,
            message: `Stopped ${result.stopped.length} channel(s)`,
            ...result
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels/batch/start', async (req, res) => {
    const { names } = req.body;

    if (!names || !Array.isArray(names) || names.length === 0) {
        return res.status(400).json({ success: false, error: 'Names array required' });
    }

    try {
        const result = await channelManager.startChannelsBatch(names);
        res.json({
            success: true,
            message: `Started ${result.started.length} channel(s)`,
            ...result
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// ============ CHANNEL CONTROL (param routes - must be AFTER batch) ============

app.post('/api/channels/:name/restart', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    try {
        await channelManager.restartChannel(name);
        res.json({ success: true, message: `Channel '${name}' restarted` });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels/:name/stop', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    try {
        await channelManager.stopChannel(name);
        res.json({ success: true, message: `Channel '${name}' stopped` });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.post('/api/channels/:name/start', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    try {
        await channelManager.startChannel(name);
        res.json({ success: true, message: `Channel '${name}' started` });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

app.get('/api/channels/:name/log', async (req, res) => {
    const name = sanitizeChannelName(req.params.name);
    if (!name) return res.status(400).json({ success: false, error: 'Invalid channel name' });
    try {
        const lines = parseInt(req.query.lines) || 50;
        const log = await channelManager.getChannelLog(name, lines);
        res.json({ success: true, log });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// ============ MASTER PLAYLIST ============

function m3uAttr(str) {
    if (!str) return '';
    return str.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

app.get('/playlist.m3u', async (req, res) => {
    try {
        const channels = await channelManager.getAllChannels();
        const baseUrl = getBaseUrl(req);

        let playlist = '#EXTM3U\n';
        playlist += '#PLAYLIST:HLS Restreamer\n\n';

        for (const channel of channels) {
            if (channel.status === 'running') {
                const safeName = m3uAttr(channel.name);
                const safeGroup = m3uAttr(channel.group);
                const safeTvgId = m3uAttr(channel.tvgId);
                const safeTvgName = m3uAttr(channel.tvgName || channel.name);
                const safeTvgLogo = m3uAttr(channel.tvgLogo);

                let extinf = `#EXTINF:-1`;
                if (safeTvgId || safeTvgName || safeTvgLogo) {
                    extinf += ` tvg-id="${safeTvgId}" tvg-name="${safeTvgName}" tvg-logo="${safeTvgLogo}"`;
                }
                if (safeGroup) {
                    extinf += ` group-title="${safeGroup}"`;
                }
                extinf += `,${safeName}\n`;
                playlist += extinf;
                playlist += `${baseUrl}/hls/${channel.name}/index.m3u8\n`;
            }
        }

        res.set('Content-Type', 'audio/x-mpegurl');
        res.send(playlist);
    } catch (error) {
        res.status(500).send('#EXTM3U\n');
    }
});

// ============ STATS ============

app.get('/api/stats', async (req, res) => {
    try {
        const stats = await channelManager.getStats();
        const segmentCount = await countSegments();

        res.json({
            success: true,
            stats: {
                ...stats,
                totalSegments: segmentCount,
                uptime: process.uptime(),
                memory: process.memoryUsage(),
                platform: process.platform,
                nodeVersion: process.version,
                config: {
                    segmentPath: config.hls.segmentPath,
                    segmentDuration: config.hls.segmentDuration,
                    playlistLength: config.hls.playlistLength,
                    maxChannels: config.limits.maxChannels
                }
            }
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// ============ UTILITIES ============

function getBaseUrl(req) {
    const protocol = req.headers['x-forwarded-proto'] || 'http';
    const host = req.headers['x-forwarded-host'] || req.headers.host;
    return `${protocol}://${host}`;
}

async function countSegments() {
    try {
        const dir = config.hls.segmentPath;
        let count = 0;
        const entries = await fs.readdir(dir).catch(() => []);
        for (const entry of entries) {
            const full = path.join(dir, entry);
            const stat = await fs.stat(full).catch(() => null);
            if (stat && stat.isDirectory()) {
                const files = await fs.readdir(full).catch(() => []);
                count += files.filter(f => f.endsWith('.ts')).length;
            }
        }
        return count;
    } catch {
        return 0;
    }
}

// ============ ERROR HANDLERS ============

app.use((req, res) => {
    res.status(404).json({ error: 'Not found' });
});

app.use((err, req, res, next) => {
    console.error(chalk.red('Server Error:'), err);
    res.status(500).json({ error: 'Internal server error' });
});

process.on('uncaughtException', (err) => {
    console.error(chalk.red('Uncaught Exception:'), err.message);
});

process.on('unhandledRejection', (err) => {
    console.error(chalk.red('Unhandled Rejection:'), err?.message || err);
});

// ============ STARTUP ============

const PORT = config.server.port;
const HOST = config.server.host;

async function startServer() {
    // Start listening immediately — restore channels in background
    const server = app.listen(PORT, HOST, () => {
        console.log(chalk.green.bold('\n╔════════════════════════════════════════════╗'));
        console.log(chalk.green.bold('║   HLS RESTREAMING SERVER STARTED           ║'));
        console.log(chalk.green.bold('╚════════════════════════════════════════════╝\n'));
        console.log(chalk.cyan(`Server running on: http://${HOST}:${PORT}`));
        console.log(chalk.cyan(`HLS Endpoint: http://${HOST}:${PORT}/hls/`));
        console.log(chalk.cyan(`Admin Panel: http://${HOST}:${PORT}/`));
        console.log(chalk.cyan(`Stats API: http://${HOST}:${PORT}/api/stats`));
        console.log(chalk.yellow(`\nPress Ctrl+C to stop\n`));
    });

    server.on('error', (err) => {
        console.error(chalk.red('Server error:'), err.message);
        if (err.code === 'EADDRINUSE') {
            console.error(chalk.red(`Port ${PORT} is already in use. Kill the existing process or use a different port.`));
        }
        process.exit(1);
    });

    // Restore channels in background
    channelManager.ready().catch(err => {
        console.error(chalk.red('Channel restoration error:'), err.message);
    });

    async function shutdown() {
        console.log(chalk.yellow('\nShutting down gracefully...'));
        server.close();
        await channelManager.stopAll();
        setTimeout(() => process.exit(1), 30000).unref();
    }

    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
}

startServer().catch(err => {
    console.error(chalk.red('Startup failed:'), err);
    process.exit(1);
});
