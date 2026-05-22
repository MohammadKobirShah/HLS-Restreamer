const https = require('https');
const http = require('http');
const url = require('url');

const MAX_RESPONSE_SIZE = 10 * 1024 * 1024;
const MAX_REDIRECTS = 10;

class M3UParser {

    async fetchAndParse(playlistUrl) {
        const content = await this._fetchUrl(playlistUrl, 0);
        return this._parse(content, playlistUrl);
    }

    _fetchUrl(targetUrl, redirectCount = 0) {
        return new Promise((resolve, reject) => {
            if (redirectCount > MAX_REDIRECTS) {
                return reject(new Error('Too many redirects'));
            }

            const parsed = new url.URL(targetUrl);
            const mod = parsed.protocol === 'https:' ? https : http;

            const options = {
                hostname: parsed.hostname,
                port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
                path: parsed.pathname + parsed.search,
                method: 'GET',
                headers: {
                    'User-Agent': 'Mozilla/5.0 (compatible; HLSRestreamer/2.0)',
                    'Accept': '*/*'
                },
                timeout: 15000
            };

            const req = mod.get(options, (res) => {
                if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                    const redirectUrl = new url.URL(res.headers.location, targetUrl).href;
                    return this._fetchUrl(redirectUrl, redirectCount + 1).then(resolve).catch(reject);
                }

                if (res.statusCode !== 200) {
                    return reject(new Error(`HTTP ${res.statusCode} fetching playlist`));
                }

                const chunks = [];
                let totalSize = 0;
                res.on('data', chunk => {
                    totalSize += chunk.length;
                    if (totalSize > MAX_RESPONSE_SIZE) {
                        req.destroy();
                        return reject(new Error('Response too large'));
                    }
                    chunks.push(chunk);
                });
                res.on('end', () => resolve(Buffer.concat(chunks).toString('utf-8')));
            });

            req.on('error', reject);
            req.on('timeout', () => { req.destroy(); reject(new Error('Request timeout')); });
        });
    }

    _parse(content, baseUrl) {
        const lines = content.split(/\r?\n/);
        const channels = [];
        let currentExtinf = null;

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();

            if (line.startsWith('#EXTINF:')) {
                currentExtinf = this._parseExtinf(line);
                continue;
            }

            if (line && !line.startsWith('#') && currentExtinf) {
                const streamUrl = this._resolveUrl(line, baseUrl);
                channels.push({
                    ...currentExtinf,
                    source: streamUrl
                });
                currentExtinf = null;
            }

            if (line.startsWith('#EXTM3U')) {
                continue;
            }
        }

        return channels;
    }

    _parseExtinf(line) {
        const info = {
            name: 'Unknown',
            logo: null,
            group: null,
            tvgId: null,
            tvgName: null,
            tvgLogo: null
        };

        const tvgIdMatch = line.match(/tvg-id="([^"]*)"/i);
        if (tvgIdMatch) info.tvgId = tvgIdMatch[1] || null;

        const tvgNameMatch = line.match(/tvg-name="([^"]*)"/i);
        if (tvgNameMatch) info.tvgName = tvgNameMatch[1] || null;

        const tvgLogoMatch = line.match(/tvg-logo="([^"]*)"/i);
        if (tvgLogoMatch) info.tvgLogo = tvgLogoMatch[1] || null;

        const logoMatch = line.match(/logo="([^"]*)"/i);
        if (logoMatch) info.logo = logoMatch[1] || null;

        const groupMatch = line.match(/group-title="([^"]*)"/i);
        if (groupMatch) info.group = groupMatch[1] || null;

        const nameMatch = line.match(/^#EXTINF:[-0-9.]+,(.+)$/);
        if (nameMatch) {
            info.name = nameMatch[1].trim();
        }

        if (info.tvgName && !info.name) {
            info.name = info.tvgName;
        }

        return info;
    }

    _resolveUrl(streamUrl, baseUrl) {
        if (streamUrl.startsWith('http://') || streamUrl.startsWith('https://')) {
            return streamUrl;
        }
        try {
            const resolved = new url.URL(streamUrl, baseUrl);
            return resolved.href;
        } catch {
            return streamUrl;
        }
    }
}

module.exports = M3UParser;
