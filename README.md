# GeoServer Migration Tools

This project provides a set of tools to migrate GeoServer layers, styles, and feature types between environments (dev, test, prod) using the GeoServer REST API.

## Usage

Run the script from WSL or a Linux environment:

```
./migrate-layer.sh <src_env> <tgt_env> <src_workspace> <tgt_workspace> <layer_name>
```
- `<src_env>`: Source environment name (e.g., dev, tst, prd)
- `<tgt_env>`: Target environment name (e.g., dev, tst, prd)
- `<src_workspace>`: Source GeoServer workspace name
- `<tgt_workspace>`: Target GeoServer workspace name
- `<layer_name>`: Name of the layer to migrate

## What the script does
- Fetches layer, feature type, and style from the source GeoServer (using the source workspace)
- Cleans and prepares JSON for import
- Ensures feature type and layer are overwritten in the target GeoServer (using the target workspace)
- Handles styles globally (not workspace-specific)
- Stores all downloaded/intermediate files in the `./tmp/` directory

## Required Packages (WSL/Ubuntu)

You may need to install the following packages:

- `curl` (for HTTP requests)
- `jq` (for JSON processing)
- `sed` (for string manipulation)
- `bash` (if not already present)

Install them with:
```
sudo apt update
sudo apt install curl jq sed bash
```

## Notes
- Make sure `.env.dev`, `.env.tst`, `.env.prd` files exist and are properly configured with GeoServer credentials and URLs.
- The script assumes you have network access to both source and target GeoServer instances.
- You can now migrate between different workspaces on the source and target servers by specifying them as arguments.
- All temporary files are stored in `./tmp/`.

## Troubleshooting
- If migration fails, check the output for curl errors and ensure all required packages are installed.
- Ensure your GeoServer user has sufficient permissions for REST API operations.

## License
This project is intended for internal use. Adapt as needed for your environment.

## .env File Structure

Each environment file (.env.dev, .env.tst, .env.prd) should be placed in the project root and contain the following variables:

```
GEOSERVER_URL=https://your-geoserver-url/rest
GEOSERVER_USER=your-username
GEOSERVER_PASS=your-password
```

- `GEOSERVER_URL`: The base REST API URL for the GeoServer instance (should end with `/rest`).
- `GEOSERVER_USER`: Username for GeoServer REST API access.
- `GEOSERVER_PASS`: Password for GeoServer REST API access.

The script automatically loads the correct .env file based on the migration mode.
