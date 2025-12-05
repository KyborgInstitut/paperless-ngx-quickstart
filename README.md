# Paperless-ngx Quick Start

<p align="center">
  <strong>A project by Kyborg Institut & Research</strong><br>
  <em>Free tools for free people</em>
</p>

<p align="center">
  <a href="https://kyborg-institut.com">Website</a> •
  <a href="AUTHOR.md">About the Author</a> •
  <a href="#support-our-work">Support</a> •
  <a href="LICENSE">MIT License</a>
</p>

---

A comprehensive management tool for deploying and managing Paperless-ngx on Ubuntu 24.04 LTS. This project provides an interactive, beginner-friendly interface while offering advanced features for experienced users.

**Why this tool?** Created out of practical necessity - managing documents, GoBD compliance, and bureaucracy for small businesses shouldn't require expensive proprietary software or a dedicated IT department. This tool gives you professional-grade document management in minutes, not months.

## Features

- **One-Command Setup**: Complete installation with guided configuration
- **Automatic Dependency Management**: Installs Docker, tools, and all requirements
- **Performance Optimization**: Redis caching tuned for your document collection size
- **SSL/HTTPS Support**: Self-signed certificates with multiple security modes
- **Backup & Restore**: Automated backups with scheduling and encryption
- **Compliance Ready**: DSGVO (GDPR) and GoBD support for German tax requirements
- **Health Monitoring**: Automatic health checks with email alerts
- **Beginner-Friendly**: Clear explanations and guided workflows

## Quick Start

```bash
# Clone the repository
git clone https://github.com/kyborginstitut/paperless-ngx-quickstart.git
cd paperless-ngx-quickstart

# Run the management tool
sudo ./management.sh
```

The script will:
1. Synchronize system time (prevents APT errors)
2. Show the welcome screen with current status
3. Guide you through setup options

## System Requirements

- **OS**: Ubuntu 24.04 LTS (recommended)
- **RAM**: Minimum 4 GB (8 GB recommended for larger collections)
- **Storage**: 20 GB minimum (depends on document volume)
- **Network**: Internet connection for initial setup

## Main Menu

When you run `sudo ./management.sh`, you'll see:

```
    ____                        __
   / __ \____ _____  ___  _____/ /__  __________      ____  ____ __  __
  / /_/ / __ `/ __ \/ _ \/ ___/ / _ \/ ___/ ___/_____/ __ \/ __ `/ |/_/
 / ____/ /_/ / /_/ /  __/ /  / /  __(__  |__  )_____/ / / / /_/ />  <
/_/    \__,_/ .___/\___/_/  /_/\___/____/____/     /_/ /_/\__, /_/|_|
           /_/                                           /____/

  Document Management System - Quick Start
  ✓ System time synchronized

  Current Status:
    Dependencies:  ✓ Installed
    Configuration: ✓ Complete
    Services:      ● Running

  What would you like to do?

  Getting Started:
    1) Complete Setup (Recommended)
    2) Install Dependencies Only
    3) Configure Paperless-ngx
    4) Start Services

  Management:
    5) Open Full Management Menu
    6) View System Status

    0) Exit
```

## Installation Workflow

### Option 1: Complete Setup (Recommended)

Select option `1` for a guided setup that:

1. **Installs Dependencies** (with progress bar)
   - Docker & Docker Compose
   - OpenSSL, Samba, ACL utilities
   - All required packages

2. **Configures Paperless-ngx**
   - Admin username and password
   - Database password (auto-generated or custom)
   - Redis cache size (based on expected documents)
   - OCR languages
   - Timezone
   - Database optimization

3. **Downloads Docker Images** (with progress bar)
   - Paperless-ngx
   - PostgreSQL 16
   - Redis 7
   - Nginx
   - Gotenberg (Office document conversion)
   - Apache Tika (text extraction)

4. **Starts Services** (with progress bar)
   - All containers started and health-checked
   - Access URL displayed when complete

### Option 2: Step-by-Step Setup

For more control, you can run each step individually:
- `2` - Install Dependencies Only
- `3` - Configure Paperless-ngx
- `4` - Start Services

## Full Management Menu

Select option `5` to access all features:

```
  Setup & Configuration:
    1) Initial Setup
   10) Configure SSL/HTTPS
   12) Check/Install Dependencies

  Daily Operations:
    6) Start Services
    7) Stop Services
    8) View Status
    9) View Logs

  Backup & Updates:
    2) Create Backup
    3) Restore from Backup
    4) Schedule Automatic Backups
    5) Update Containers

  Advanced:
   11) Advanced Settings (24 options)

   13) Switch to Simple Menu
    0) Exit
```

## Advanced Settings

The Advanced Settings menu (`11`) provides 24 additional options:

### Performance & Optimization
- **Database Optimization**: PostgreSQL tuning for your hardware
- **Redis Cache Configuration**: Adjust cache size for document count
- **Bulk Import Mode**: Optimized settings for large imports

### Monitoring & Maintenance
- **Health Monitoring**: Configure automatic health checks
- **Email Alerts**: Get notified of issues
- **Log Rotation**: Manage log file sizes
- **Database Maintenance**: VACUUM, REINDEX operations

### Security
- **Security Audit**: Check your configuration
- **Fail2ban Integration**: Brute-force protection
- **Backup Encryption**: Encrypt your backups

### Document Management
- **Document Statistics**: View collection analytics
- **Duplicate Detection**: Find duplicate documents
- **Storage Analysis**: Disk usage breakdown
- **Search Index Rebuild**: Fix search issues

### Import & Export
- **Email/IMAP Import**: Import from email accounts
- **Bulk Import**: Mass document import
- **Document Export**: Export your archive

### User Management
- **User Management**: Add/remove users
- **API Token Management**: Manage API access

### Compliance (DSGVO/GoBD)
- **DSGVO Compliance**: EU data protection features
- **GoBD Compliance**: German tax requirements
- **Retention Management**: Document retention periods
- **Verfahrensdokumentation**: Generate compliance documentation

## Redis Cache Configuration

During setup, you'll configure Redis cache based on your document count:

| Cache Size | Documents | Min. RAM |
|------------|-----------|----------|
| 128 MB | up to 1,000 | 4 GB |
| 256 MB | 1,000 - 5,000 | 4 GB |
| 512 MB | 5,000 - 20,000 | 8 GB |
| 1024 MB | 20,000 - 50,000 | 8 GB |
| 2048 MB | 50,000 - 150,000 | 16 GB |
| 4096 MB | 150,000 - 500,000 | 16 GB |
| 8192 MB | 500,000 - 1,000,000 | 32 GB |

**Rule of thumb**: Redis cache should not exceed 50% of your total RAM.

## SSL/HTTPS Configuration

Three SSL modes are available:

1. **HTTP Only**: No encryption (not recommended for production)
2. **HTTPS with Redirect**: HTTP redirects to HTTPS (recommended)
3. **HTTPS Only**: HTTP connections are dropped

The script generates self-signed certificates valid for 10 years, suitable for local network use.

## Backup System

### Manual Backup
```bash
sudo ./management.sh backup
```

### Scheduled Backups
Configure via menu option `4`:
- Daily, weekly, or custom schedules
- Configurable retention period
- Optional encryption
- Automatic verification

### Backup Contents
- PostgreSQL database dump
- Document media files
- Configuration files
- Redis data

### Restore
```bash
sudo ./management.sh
# Select option 3) Restore from Backup
```

## Command Line Interface

The script supports direct commands for automation:

```bash
# Getting Started
sudo ./management.sh              # Interactive menu
sudo ./management.sh setup        # Run initial setup
sudo ./management.sh menu         # Open management menu directly

# Service Management
sudo ./management.sh start        # Start all services
sudo ./management.sh stop         # Stop all services
sudo ./management.sh status       # Show service status

# Backup & Maintenance
sudo ./management.sh backup           # Create a backup
sudo ./management.sh verify-backups   # Verify backup integrity
sudo ./management.sh auto-cleanup     # Run automatic cleanup

# Monitoring & Reports
sudo ./management.sh health-check     # Run health check
sudo ./management.sh generate-report  # Generate system report
sudo ./management.sh security-audit   # Run security audit
sudo ./management.sh statistics       # Show document statistics

# Help
sudo ./management.sh help         # Show all commands
```

## Directory Structure

```
paperless-ngx-quickstart/
├── management.sh           # Main management script
├── docker-compose.yml      # Docker service definitions
├── .env                    # Configuration (generated)
├── .env.example           # Example configuration
│
├── data/                  # Persistent data
│   ├── data/             # Application data
│   ├── media/            # Document storage
│   ├── postgres/         # Database files
│   └── redis/            # Cache data
│
├── consume/              # Drop documents here for import
├── export/               # Document exports
├── trash/                # Deleted documents
├── backups/              # Backup files
│
├── nginx/
│   ├── nginx.conf        # Active nginx configuration
│   ├── ssl/              # SSL certificates
│   └── templates/        # Configuration templates
│
├── config/
│   ├── postgres/         # PostgreSQL configuration
│   └── compliance.conf   # Compliance settings
│
└── scripts/              # Custom pre/post consumption scripts
```

## Importing Documents

### Drop Folder
Simply copy files to the `consume/` directory:
```bash
cp /path/to/document.pdf ./consume/
```

Paperless will automatically:
1. Detect the new file
2. OCR the document
3. Extract metadata
4. Add to your archive

### Subdirectories as Tags
Files in subdirectories are automatically tagged:
```bash
consume/
├── invoices/           # Tagged as "invoices"
│   └── invoice.pdf
├── contracts/          # Tagged as "contracts"
│   └── contract.pdf
└── document.pdf        # No automatic tag
```

### Network Import (SMB)
Configure SMB sharing via Advanced Settings for network access to the consume folder.

## Compliance Features

### DSGVO (GDPR) Compliance
- Export personal data (Art. 15)
- Delete personal data (Art. 17 - Right to be Forgotten)
- Search for personal data
- Audit logging
- Access control review

### GoBD Compliance (German)
- Document immutability settings
- Retention period management
- Change history tracking
- Verfahrensdokumentation generator
- Audit trail export

### Retention Periods
Default retention periods (configurable):
- Accounting documents: 10 years
- Business correspondence: 6 years
- Contracts: 10 years
- Tax documents: 10 years
- HR documents: 10 years
- General documents: 6 years

## Troubleshooting

### Services Won't Start
```bash
# Check service status
sudo ./management.sh status

# View logs
sudo ./management.sh
# Select: 9) View Logs

# Check Docker
sudo docker compose ps
sudo docker compose logs webserver
```

### APT "Release file not valid yet" Error
The script automatically synchronizes system time on startup. If issues persist:
```bash
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
```

### OCR Not Working
1. Check if Tika and Gotenberg are running
2. Verify OCR language is installed
3. Check webserver logs for errors

### Search Not Finding Documents
Rebuild the search index via:
- Advanced Settings → Search Index Rebuild

### Permission Issues
```bash
# Fix ownership
sudo chown -R 1000:1000 ./data ./consume ./export

# Fix permissions
sudo chmod -R 755 ./data ./consume ./export
```

## Updating

### Update Containers
```bash
sudo ./management.sh
# Select: 5) Update Containers
```

This will:
1. Create a backup
2. Pull latest images
3. Restart services
4. Verify health

### Update Management Script
```bash
git pull origin main
```

## Security Considerations

- **Change default passwords** during initial setup
- **Enable HTTPS** for production use
- **Configure Fail2ban** for brute-force protection
- **Regular backups** with encryption enabled
- **Keep containers updated** for security patches

Run the security audit regularly:
```bash
sudo ./management.sh security-audit
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Support Our Work

If this tool has helped you, consider:

- **Star this repo** - It helps others discover the project
- **Share** - Tell colleagues, friends, or your network
- **Contribute** - Submit improvements, translations, or documentation
- **Report issues** - Help us improve by reporting bugs or suggesting features

**Get Help:**
- [GitHub Issues](https://github.com/kyborginstitut/paperless-ngx-quickstart/issues)
- [Paperless-ngx Documentation](https://docs.paperless-ngx.com)

**Connect with Kyborg Institut:**
- Website: [kyborg-institut.com](https://kyborg-institut.com)
- Social Media: [@kyborginstitut](https://instagram.com/kyborginstitut)

## Acknowledgments

- [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) - The excellent document management system
- [Docker](https://www.docker.com/) - Container platform
- [PostgreSQL](https://www.postgresql.org/) - Database
- [Redis](https://redis.io/) - Caching
- [Claude AI](https://anthropic.com) - Development assistance

---

<p align="center">
  <strong>Kyborg Institut & Research</strong><br>
  <em>Founded by Detlef Harald Alke • Continued by Tobias O. R. Alke, M.A.</em><br><br>
  <a href="https://kyborg-institut.com">kyborg-institut.com</a> •
  <a href="https://github.com/kyborginstitut">GitHub</a> •
  <a href="https://instagram.com/kyborginstitut">@kyborginstitut</a>
</p>

<p align="center">
  <em>In the spirit of true altruism: freely given, freely received.</em>
</p>
