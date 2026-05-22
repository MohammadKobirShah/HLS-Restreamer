module.exports = {
  apps: [
    {
      name: 'hls-server',
      script: './server.js',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '1G',
      env: {
        NODE_ENV: 'production',
        PORT: 3000
      },
      error_file: './logs/server-error.log',
      out_file: './logs/server-out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z'
    },
    {
      name: 'hls-cleanup',
      script: './cleanup.py',
      interpreter: 'python3',
      autorestart: true,
      watch: false,
      error_file: './logs/cleanup-error.log',
      out_file: './logs/cleanup-out.log'
    }
  ]
};
