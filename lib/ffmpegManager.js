const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const chalk = require('chalk');

class FFmpegManager {
    constructor(config) {
        this.config = config;
        this.processes = new Map();
    }

    createProcess(name, source, outputDir) {
        const outputPath = path.join(outputDir, 'index.m3u8');
        const segmentPattern = path.join(outputDir, 'segment_%d.ts');

        const args = [
            ...this.config.ffmpeg.defaultOptions,
            '-re',
            '-i', source,
            '-c', 'copy',
            '-f', 'hls',
            '-hls_time', this.config.hls.segmentDuration.toString(),
            '-hls_list_size', Math.ceil(this.config.hls.playlistLength / this.config.hls.segmentDuration).toString(),
            '-hls_flags', 'delete_segments+append_list',
            '-hls_segment_filename', segmentPattern,
            '-y',
            outputPath
        ];

        const proc = spawn(this.config.ffmpeg.path, args);
        this.processes.set(name, proc);

        this._setupLogging(name, proc);

        return proc;
    }

    _setupLogging(name, proc) {
        const logDir = path.join('logs', 'channels');
        const logFile = path.join(logDir, `${name}.log`);
        const logStream = fs.createWriteStream(logFile, { flags: 'a' });

        proc.stderr.pipe(logStream);

        proc.on('error', (error) => {
            console.error(chalk.red(`❌ FFmpeg error for ${name}:`), error.message);
        });

        proc.on('close', (code) => {
            console.log(chalk.yellow(`⚠️  FFmpeg ${name} exited with code ${code}`));
            this.processes.delete(name);
        });
    }

    killProcess(name) {
        const proc = this.processes.get(name);
        if (proc) {
            proc.kill('SIGTERM');
            this.processes.delete(name);
            return true;
        }
        return false;
    }

    killAll() {
        for (const [name, proc] of this.processes) {
            proc.kill('SIGTERM');
        }
        this.processes.clear();
    }

    getProcess(name) {
        return this.processes.get(name) || null;
    }

    get runningCount() {
        return this.processes.size;
    }
}

module.exports = FFmpegManager;
