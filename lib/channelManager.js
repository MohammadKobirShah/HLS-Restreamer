const { spawn } = require('child_process');
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const chalk = require('chalk');
const low = require('lowdb');
const FileSync = require('lowdb/adapters/FileSync');

class ChannelManager {
    constructor(config) {
        this.config = config;
        this.channels = new Map();
        this._ready = null;

        const adapter = new FileSync('channels.json');
        this.db = low(adapter);
        this.db.defaults({ channels: [] }).write();

        this._ready = this._init();
    }

    async ready() {
        if (this._ready) await this._ready;
    }

    async _init() {
        const savedChannels = this.db.get('channels').value();
        const restored = [];
        for (const ch of savedChannels) {
            if (ch.autoRestart !== false) {
                restored.push(ch);
            }
        }
        // Restore in parallel with a global timeout
        await Promise.race([
            Promise.all(restored.map(ch => this._restoreOne(ch))),
            new Promise(resolve => setTimeout(resolve, 30000))
        ]);
    }

    async _restoreOne(ch) {
        try {
            const channelDir = path.join(this.config.hls.segmentPath, ch.name);
            await fs.mkdir(channelDir, { recursive: true });

            const channel = {
                name: ch.name,
                source: ch.source,
                bitrate: ch.bitrate || 5000,
                status: 'starting',
                createdAt: ch.createdAt || Date.now(),
                pid: null,
                process: null,
                logStream: null,
                restartTimeout: null,
                stopRequested: false,
                autoRestart: true,
                restartCount: 0,
                group: ch.group || null,
                logo: ch.logo || null,
                tvgId: ch.tvgId || null,
                tvgName: ch.tvgName || null,
                tvgLogo: ch.tvgLogo || null
            };

            this.channels.set(ch.name, channel);
            await this.startFFmpeg(channel);
            console.log(chalk.green(`Restored channel: ${ch.name}`));
        } catch (error) {
            console.error(chalk.red(`Failed to restore ${ch.name}:`, error.message));
        }
    }

    async addChannel(name, source, bitrate = 5000, extra = {}) {
        if (this.channels.has(name)) {
            throw new Error(`Channel '${name}' already exists`);
        }

        if (this.channels.size >= this.config.limits.maxChannels) {
            throw new Error(`Maximum channel limit (${this.config.limits.maxChannels}) reached`);
        }

        const channelDir = path.join(this.config.hls.segmentPath, name);
        await fs.mkdir(channelDir, { recursive: true });

        const channel = {
            name,
            source,
            bitrate,
            status: 'starting',
            createdAt: Date.now(),
            pid: null,
            process: null,
            logStream: null,
            restartTimeout: null,
            stopRequested: false,
            autoRestart: extra.autoRestart !== false,
            restartCount: 0,
            group: extra.group || null,
            logo: extra.logo || null,
            tvgId: extra.tvgId || null,
            tvgName: extra.tvgName || null,
            tvgLogo: extra.tvgLogo || null
        };

        try {
            this.channels.set(name, channel);
            await this.startFFmpeg(channel);

            this.db.get('channels')
                .push({
                    name,
                    source,
                    bitrate,
                    autoRestart: channel.autoRestart,
                    group: channel.group,
                    logo: channel.logo,
                    tvgId: channel.tvgId,
                    tvgName: channel.tvgName,
                    tvgLogo: channel.tvgLogo,
                    createdAt: channel.createdAt
                })
                .write();

            console.log(chalk.green(`Channel started: ${name}`));
            return channel;
        } catch (error) {
            if (channel.process) {
                channel.process.kill('SIGTERM');
            }
            this.channels.delete(name);
            await fs.rmdir(channelDir, { recursive: true }).catch(() => {});
            throw error;
        }
    }

    async _killProcess(proc) {
        if (!proc) return;
        return new Promise((resolve) => {
            const timeout = setTimeout(() => {
                try { proc.kill('SIGKILL'); } catch {}
            }, 5000);
            proc.once('exit', () => {
                clearTimeout(timeout);
                resolve();
            });
            try { proc.kill('SIGTERM'); } catch { resolve(); }
        });
    }

    async startFFmpeg(channel) {
        const outputPath = path.join(this.config.hls.segmentPath, channel.name, 'index.m3u8');

        const args = [
            ...this.config.ffmpeg.defaultOptions,
            '-re',
            '-i', channel.source,
            '-c', 'copy',
            '-f', 'hls',
            '-hls_time', this.config.hls.segmentDuration.toString(),
            '-hls_list_size', Math.ceil(this.config.hls.playlistLength / this.config.hls.segmentDuration).toString(),
            '-hls_flags', 'delete_segments+append_list',
            '-hls_segment_filename', path.join(this.config.hls.segmentPath, channel.name, 'segment_%d.ts'),
            '-y',
            outputPath
        ];

        const ffmpeg = spawn(this.config.ffmpeg.path, args);

        channel.process = ffmpeg;
        channel.pid = ffmpeg.pid;
        channel.status = 'running';
        channel.restartCount = 0;

        const logDir = path.join('logs', 'channels');
        await fs.mkdir(logDir, { recursive: true });
        const logFile = path.join(logDir, `${channel.name}.log`);

        if (channel.logStream) {
            channel.logStream.end();
        }
        const logStream = fsSync.createWriteStream(logFile, { flags: 'a' });
        channel.logStream = logStream;

        ffmpeg.stderr.pipe(logStream);

        ffmpeg.on('error', (error) => {
            console.error(chalk.red(`FFmpeg error for ${channel.name}:`), error.message);
            channel.status = 'error';
        });

        ffmpeg.on('close', async (code) => {
            channel.process = null;
            channel.pid = null;
            channel.status = 'stopped';

            if (channel.logStream) {
                channel.logStream.end();
                channel.logStream = null;
            }

            if (!channel.stopRequested && channel.autoRestart && code !== 0 && channel.restartCount < 5) {
                channel.restartCount++;
                const delay = Math.min(5000 * Math.pow(2, channel.restartCount - 1), 120000);
                console.log(chalk.yellow(`Auto-restarting ${channel.name} in ${delay}ms (attempt ${channel.restartCount}/5)...`));

                channel.restartTimeout = setTimeout(async () => {
                    if (!this.channels.has(channel.name)) return;
                    try {
                        await this.startFFmpeg(channel);
                    } catch (error) {
                        console.error(chalk.red(`Restart failed for ${channel.name}:`, error.message));
                    }
                }, delay);
            }
            channel.stopRequested = false;
        });

        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                ffmpeg.kill('SIGTERM');
                reject(new Error('FFmpeg startup timeout'));
            }, 10000);

            ffmpeg.stderr.once('data', () => {
                clearTimeout(timeout);
                resolve();
            });

            ffmpeg.once('error', (error) => {
                clearTimeout(timeout);
                reject(error);
            });
        });
    }

    async updateChannel(name, updates) {
        const channel = this.channels.get(name);

        if (!channel) {
            throw new Error(`Channel '${name}' not found`);
        }

        const needsRestart = updates.source && updates.source !== channel.source;

        if (updates.source) channel.source = updates.source;
        if (updates.bitrate) channel.bitrate = updates.bitrate;
        if (updates.autoRestart !== undefined) channel.autoRestart = updates.autoRestart;
        if (updates.group !== undefined) channel.group = updates.group;
        if (updates.logo !== undefined) channel.logo = updates.logo;
        if (updates.tvgId !== undefined) channel.tvgId = updates.tvgId;
        if (updates.tvgName !== undefined) channel.tvgName = updates.tvgName;
        if (updates.tvgLogo !== undefined) channel.tvgLogo = updates.tvgLogo;

        this.db.get('channels')
            .find({ name })
            .assign({
                source: channel.source,
                bitrate: channel.bitrate,
                autoRestart: channel.autoRestart,
                group: channel.group,
                logo: channel.logo,
                tvgId: channel.tvgId,
                tvgName: channel.tvgName,
                tvgLogo: channel.tvgLogo
            })
            .write();

        if (needsRestart) {
            console.log(chalk.yellow(`Source changed for ${name}, restarting...`));
            if (channel.process) {
                channel.stopRequested = true;
                await this._killProcess(channel.process);
            }
            await new Promise(resolve => setTimeout(resolve, 2000));
            await this.startFFmpeg(channel);
        }

        console.log(chalk.green(`Channel updated: ${name}`));
        return this.getChannel(name);
    }

    async stopChannel(name) {
        const channel = this.channels.get(name);

        if (!channel) {
            throw new Error(`Channel '${name}' not found`);
        }

        channel.stopRequested = true;

        if (channel.restartTimeout) {
            clearTimeout(channel.restartTimeout);
            channel.restartTimeout = null;
        }

        if (channel.process) {
            await this._killProcess(channel.process);
        }

        channel.status = 'stopped';
        console.log(chalk.yellow(`Channel stopped: ${name}`));
    }

    async startChannel(name) {
        const channel = this.channels.get(name);

        if (!channel) {
            throw new Error(`Channel '${name}' not found`);
        }

        if (channel.status === 'running') {
            throw new Error(`Channel '${name}' is already running`);
        }

        const channelDir = path.join(this.config.hls.segmentPath, name);
        await fs.mkdir(channelDir, { recursive: true });

        await this.startFFmpeg(channel);
        console.log(chalk.green(`Channel started: ${name}`));
    }

    async getChannelLog(name, lines = 50) {
        const logFile = path.join('logs', 'channels', `${name}.log`);

        try {
            const stat = await fs.stat(logFile).catch(() => null);
            if (!stat) return [];

            const { spawn } = require('child_process');
            return new Promise((resolve, reject) => {
                const tail = spawn('tail', ['-n', String(lines), logFile]);
                let output = '';
                let error = '';
                tail.stdout.on('data', d => output += d);
                tail.stderr.on('data', d => error += d);
                tail.on('error', (err) => {
                    reject(err);
                });
                tail.on('close', (code) => {
                    if (code !== 0 && !output) {
                        resolve([]);
                    } else {
                        resolve(output.trim().split('\n').filter(Boolean));
                    }
                });
            });
        } catch {
            return [];
        }
    }

    async addChannelsBatch(channelList) {
        const results = { added: [], failed: [] };

        for (const ch of channelList) {
            try {
                const result = await this.addChannel(
                    ch.name,
                    ch.source,
                    ch.bitrate || 5000,
                    {
                        autoRestart: ch.autoRestart !== false,
                        group: ch.group,
                        logo: ch.logo,
                        tvgId: ch.tvgId,
                        tvgName: ch.tvgName,
                        tvgLogo: ch.tvgLogo
                    }
                );
                results.added.push(result);
            } catch (error) {
                results.failed.push({ name: ch.name, error: error.message });
            }
        }

        return results;
    }

    async removeChannelsBatch(names) {
        const results = { removed: [], failed: [] };

        for (const name of names) {
            try {
                await this.removeChannel(name);
                results.removed.push(name);
            } catch (error) {
                results.failed.push({ name, error: error.message });
            }
        }

        return results;
    }

    async restartChannelsBatch(names) {
        const results = { restarted: [], failed: [] };

        for (const name of names) {
            try {
                await this.restartChannel(name);
                results.restarted.push(name);
            } catch (error) {
                results.failed.push({ name, error: error.message });
            }
        }

        return results;
    }

    async stopChannelsBatch(names) {
        const results = { stopped: [], failed: [] };

        for (const name of names) {
            try {
                await this.stopChannel(name);
                results.stopped.push(name);
            } catch (error) {
                results.failed.push({ name, error: error.message });
            }
        }

        return results;
    }

    async startChannelsBatch(names) {
        const results = { started: [], failed: [] };

        for (const name of names) {
            try {
                await this.startChannel(name);
                results.started.push(name);
            } catch (error) {
                results.failed.push({ name, error: error.message });
            }
        }

        return results;
    }

    async removeChannel(name) {
        const channel = this.channels.get(name);

        if (!channel) {
            throw new Error(`Channel '${name}' not found`);
        }

        channel.stopRequested = true;

        if (channel.restartTimeout) {
            clearTimeout(channel.restartTimeout);
            channel.restartTimeout = null;
        }

        if (channel.process) {
            await this._killProcess(channel.process);
        }

        if (channel.logStream) {
            channel.logStream.end();
            channel.logStream = null;
        }

        this.channels.delete(name);

        this.db.get('channels')
            .remove({ name })
            .write();

        const channelDir = path.join(this.config.hls.segmentPath, name);
        await fs.rmdir(channelDir, { recursive: true }).catch(() => {});

        console.log(chalk.green(`Channel removed: ${name}`));
    }

    async restartChannel(name) {
        const channel = this.channels.get(name);

        if (!channel) {
            throw new Error(`Channel '${name}' not found`);
        }

        if (channel.restartTimeout) {
            clearTimeout(channel.restartTimeout);
            channel.restartTimeout = null;
        }

        if (channel.process) {
            channel.stopRequested = true;
            await this._killProcess(channel.process);
        }

        await new Promise(resolve => setTimeout(resolve, 2000));

        channel.restartCount = 0;
        await this.startFFmpeg(channel);

        console.log(chalk.green(`Channel restarted: ${name}`));
    }

    async getChannel(name) {
        const channel = this.channels.get(name);
        if (!channel) return null;

        return {
            name: channel.name,
            source: channel.source,
            bitrate: channel.bitrate,
            status: channel.status,
            pid: channel.pid,
            createdAt: channel.createdAt,
            restartCount: channel.restartCount,
            autoRestart: channel.autoRestart,
            group: channel.group,
            logo: channel.logo,
            tvgId: channel.tvgId,
            tvgName: channel.tvgName,
            tvgLogo: channel.tvgLogo
        };
    }

    async getAllChannels() {
        return Array.from(this.channels.values()).map(ch => ({
            name: ch.name,
            source: ch.source,
            bitrate: ch.bitrate,
            status: ch.status,
            pid: ch.pid,
            createdAt: ch.createdAt,
            autoRestart: ch.autoRestart,
            group: ch.group,
            logo: ch.logo,
            tvgId: ch.tvgId,
            tvgName: ch.tvgName,
            tvgLogo: ch.tvgLogo
        }));
    }

    getChannelCount() {
        return this.channels.size;
    }

    async getStats() {
        const channels = Array.from(this.channels.values());

        return {
            totalChannels: channels.length,
            runningChannels: channels.filter(ch => ch.status === 'running').length,
            stoppedChannels: channels.filter(ch => ch.status === 'stopped').length,
            errorChannels: channels.filter(ch => ch.status === 'error').length
        };
    }

    async stopAll() {
        console.log(chalk.yellow('Stopping all channels...'));

        for (const [, channel] of this.channels) {
            channel.stopRequested = true;
            if (channel.restartTimeout) {
                clearTimeout(channel.restartTimeout);
                channel.restartTimeout = null;
            }
            if (channel.process) {
                await this._killProcess(channel.process);
            }
            if (channel.logStream) {
                channel.logStream.end();
                channel.logStream = null;
            }
        }

        this.channels.clear();
        console.log(chalk.green('All channels stopped'));
    }
}

module.exports = ChannelManager;
