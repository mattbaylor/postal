# Contributing to Postal

This doc explains how to go about running Postal in development to allow you to make contributions to the project.

## Dependencies

You will need a MySQL database server to get started. Postal needs to be able to make databases within that server whenever new mail servers are created so the permissions that you use should be suitable for that.

You'll also need Ruby. Postal currently uses Ruby 3.2.2. Install that using whichever version manager takes your fancy - rbenv, asdf, rvm etc.

## Clone

You'll need to clone the repository

```
git clone git@github.com:postalserver/postal
```

Once cloned, you can install the Ruby dependencies using bundler.

```
bundle install
```

## Configuration

Configuration is handled using a config file. This lives in `config/postal/postal.yml`. An example configuration file is provided in `config/examples/development.yml`. This example is for development use only and not an example for production use.

You'll also need a key for signing. You can generate one of these like this:

```
openssl genrsa -out config/postal/signing.key 2048
```

If you're running the tests (and you probably should be), you'll find an example file for test configuration in `config/examples/test.yml`. This should be placed in `config/postal/postal.test.yml` with the appropriate values.

If you prefer, you can configure Postal using environment variables. These should be placed in `.env` or `.env.test` as apprpriate.

## Running

The neatest way to run postal is to ensure that `./bin` is your `$PATH` and then use one of the following commands.

* `bin/dev` - will run all components of the application using Foreman
* `bin/postal` - will run the Postal binary providing access to running individual components or other tools.

## Database initialization

Use the commands below to initialize your database and make your first user.

```
postal initialize
postal make-user
```

## Commit Message Convention (Edify Fork)

This fork of Postal uses **Conventional Commits** to distinguish between Edify-specific changes and core Postal modifications that could be contributed upstream.

### Format

```
<type>(<scope>): <description>

[optional body]
```

### Types

**Edify-Specific:**
- `edify(branding)`: User-facing text changes (Postal → Edify)
- `edify(ui)`: Visual/styling changes specific to Edify
- `edify(docs)`: Edify-specific documentation
- `edify(feature)`: Edify-specific features (monitoring, deployment, etc.)
- `edify(fix)`: Bug fixes specific to Edify deployments
- `edify(chore)`: Edify-specific maintenance tasks

**Core Postal (could be upstreamed):**
- `postal(fix)`: Bug fixes that benefit core Postal
- `postal(feat)`: New features for core functionality
- `postal(deps)`: Dependency updates
- `postal(chore)`: Maintenance, refactoring
- `postal(docs)`: Documentation improvements
- `postal(test)`: Test additions or improvements
- `postal(release)`: Version releases

### Examples

```bash
# Edify branding changes
edify(branding): Replace "Postal" with "Edify" in email templates
edify(ui): Update primary color scheme to match Edify brand
edify(feature): Add automated health monitoring scripts

# Core Postal improvements
postal(fix): Resolve SMTP authentication timeout issues
postal(feat): Add Prometheus metrics for message queue latency
postal(deps): Upgrade Rails to 7.1.5
```

### Filtering Commits

```bash
# Show only Edify changes
git log --grep="edify("

# Show only branding changes
git log --grep="edify(branding)"

# Show only core Postal changes
git log --grep="postal("

# Generate Edify-specific changelog
git log --grep="edify(" --pretty=format:"- %s (%h)" --reverse
```

### Why This Convention?

1. **Clear Separation**: Easy to identify fork-specific vs. upstream changes
2. **Upstream Contributions**: Quickly identify commits that could be contributed back
3. **Automated Changelogs**: Compatible with changelog generation tools
4. **Git Filtering**: Easy to filter commits by type or scope
5. **Merge Tracking**: Simplifies merging upstream updates

### Best Practices

- Write clear, descriptive commit messages
- Explain **why** the change was made, not just **what** changed
- Keep commits focused on a single logical change
- Reference issue numbers when applicable
- Use imperative mood ("Add feature" not "Added feature")
