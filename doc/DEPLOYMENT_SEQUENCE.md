# Deployment Command Sequence - Edify Release

## Your Decisions:
1. ✓ Merge to main (Edify becomes official)
2. ✓ Docker Hub: `mattbaylor/postalserver`
3. ✓ Version: Follow upstream pattern + edify suffix
4. ✓ Keep all commits

## Version Strategy

### Upstream Pattern Analysis
- Upstream uses semantic versioning: `3.3.4`, `3.3.3`, `3.3.2`
- Uses release-please for automated releases
- Pattern: `MAJOR.MINOR.PATCH`

### Recommended Versioning for Your Fork

Since you're maintaining a fork with customizations:

**Option A: Fork Version (RECOMMENDED)**
```
3.3.4-edify.1
```
- Base: `3.3.4` (upstream version you forked from)
- Suffix: `-edify.1` (your customization number)
- Next release: `3.3.4-edify.2`, `3.3.4-edify.3`, etc.
- When merging upstream 3.3.5: `3.3.5-edify.1`

**Option B: Independent Version**
```
1.0.0-edify
```
- Treat as completely separate product
- Version independently from upstream

**Option C: Date-Based**
```
3.3.4-edify-20241125
```
- Base version + edify + date
- Easy to track when built

### RECOMMENDATION: Use Option A - `3.3.4-edify.1`

**Why:**
- Clear relationship to upstream version
- Easy to merge future upstream updates
- Clear your customization iteration
- Follows semantic versioning conventions

---

## Complete Command Sequence

Execute these commands in order. I've added verification steps between each phase.

---

### PHASE 1: Clean Up Git

```bash
# Navigate to repo
cd /Users/matt/repo/postal

# Verify you're on the right branch
git branch --show-current
# Expected output: AmpersandUrlHandling

# Review what will be pushed
git log origin/AmpersandUrlHandling..HEAD --oneline
# Expected: 5 commits

# Clean up old stash (since work is now properly committed)
git stash list
git stash drop stash@{0}

# Verify stash is cleared
git stash list
# Expected: empty
```

---

### PHASE 2: Push to GitHub

```bash
# Push your branch (force-with-lease since history was rewritten)
git push origin AmpersandUrlHandling --force-with-lease

# Verify push succeeded
git status
# Expected: "Your branch is up to date with 'origin/AmpersandUrlHandling'"

# Fetch to confirm
git fetch origin
git log origin/AmpersandUrlHandling --oneline -5
# Should show all your recent commits
```

---

### PHASE 3: Merge to Main

```bash
# Switch to main branch
git checkout main

# Verify main is clean and up to date
git status
git pull origin main

# Merge AmpersandUrlHandling into main
git merge AmpersandUrlHandling --no-ff -m "Merge AmpersandUrlHandling: Edify rebrand with IIS ampersand fix

- Complete UI rebrand from Postal to Edify
- Fix URL encoding for IIS compatibility  
- Add comprehensive documentation
- All user-facing text updated to Edify branding"

# Verify merge succeeded
git log --oneline -10
# Should show merge commit + all 5 commits from branch

# Push main to remote
git push origin main

# Verify push
git status
# Expected: "Your branch is up to date with 'origin/main'"
```

---

### PHASE 4: Create Version Tag

```bash
# Still on main branch
git branch --show-current
# Expected: main

# Create annotated tag
git tag -a 3.3.4-edify.1 -m "Release 3.3.4-edify.1 - Edify Rebrand

Based on Postal 3.3.4 with the following changes:

Features:
- Complete Edify rebrand (all user-facing text)
- Comprehensive rebranding documentation

Bug Fixes:
- Fix URL encoding for IIS compatibility (ampersand handling)

Documentation:
- Add AMPERSAND_FIX.md
- Add REBRANDING_GUIDE.md
- Add REPO_MAINTENANCE_PLAN.md"

# Verify tag was created
git tag -l "3.3.4*"
# Expected: 3.3.4-edify.1

# Show tag details
git show 3.3.4-edify.1
# Should show tag message and commit details

# Push tag to remote
git push origin 3.3.4-edify.1

# Verify tag pushed
git ls-remote --tags origin | grep edify
# Should show: refs/tags/3.3.4-edify.1
```

---

### PHASE 5: Build Docker Image

```bash
# Ensure you're on main (or checkout the tag)
git checkout main

# Clean any previous builds
docker system prune -f

# Build with version tag
docker build \
  --build-arg VERSION=3.3.4-edify.1 \
  --build-arg BRANCH=main \
  -t mattbaylor/postalserver:3.3.4-edify.1 \
  -t mattbaylor/postalserver:edify \
  -t mattbaylor/postalserver:latest \
  .

# This will take 10-15 minutes...

# Verify build succeeded
docker images | grep postalserver
# Should show 3 tags for the same image ID

# Check image size
docker images mattbaylor/postalserver:3.3.4-edify.1 --format "{{.Size}}"
```

---

### PHASE 6: Test Docker Image Locally

```bash
# Test the version command
docker run --rm mattbaylor/postalserver:3.3.4-edify.1 postal version
# Expected: 3.3.4-edify.1

# Test help command
docker run --rm mattbaylor/postalserver:3.3.4-edify.1 postal --help

# Optional: Start a test container (requires config)
# docker run -it --rm mattbaylor/postalserver:3.3.4-edify.1 /bin/bash
```

---

### PHASE 7: Push to Docker Hub

```bash
# Login to Docker Hub (if not already logged in)
docker login
# Enter username: mattbaylor
# Enter password: <your-docker-hub-password>

# Push versioned tag
docker push mattbaylor/postalserver:3.3.4-edify.1

# This will take 5-10 minutes depending on connection...

# Push edify tag (latest Edify build)
docker push mattbaylor/postalserver:edify

# Push latest tag (if you want this to be the default)
docker push mattbaylor/postalserver:latest

# Verify all tags pushed
docker search mattbaylor/postalserver
```

---

### PHASE 8: Verification

```bash
# Pull from Docker Hub to verify
docker pull mattbaylor/postalserver:3.3.4-edify.1

# Test pulled image
docker run --rm mattbaylor/postalserver:3.3.4-edify.1 postal version
# Expected: 3.3.4-edify.1

# Check GitHub
# Visit: https://github.com/mattbaylor/postal/tags
# Should see: 3.3.4-edify.1

# Check GitHub main branch
# Visit: https://github.com/mattbaylor/postal/tree/main
# Should show merge commit

# Check Docker Hub
# Visit: https://hub.docker.com/r/mattbaylor/postalserver/tags
# Should show: 3.3.4-edify.1, edify, latest
```

---

## Post-Deployment Cleanup

```bash
# Switch back to development branch (optional)
git checkout AmpersandUrlHandling

# Or stay on main if that's your primary branch now
git checkout main

# Clean up local Docker images (optional)
docker image prune -a
```

---

## Summary of What Will Be Created

### Git
- ✓ Branch `AmpersandUrlHandling` pushed to GitHub (5 new commits)
- ✓ Branch `main` updated with merge commit
- ✓ Tag `3.3.4-edify.1` on main branch
- ✓ Old stash removed

### Docker Hub
- ✓ `mattbaylor/postalserver:3.3.4-edify.1` (specific version)
- ✓ `mattbaylor/postalserver:edify` (latest Edify)
- ✓ `mattbaylor/postalserver:latest` (latest overall)

### Files Changed (vs upstream 3.3.4)
- 19 files modified
- 3 documentation files added (in doc/)
- Complete Edify rebrand
- IIS ampersand fix

---

## Future Releases

### For Next Edify Update (No Upstream Merge)
```bash
# Make changes...
git commit -m "fix: something"

# Tag new version
git tag -a 3.3.4-edify.2 -m "Release 3.3.4-edify.2"
git push origin 3.3.4-edify.2

# Build Docker
docker build -t mattbaylor/postalserver:3.3.4-edify.2 .
docker push mattbaylor/postalserver:3.3.4-edify.2
```

### When Merging Upstream 3.3.5
```bash
# Add upstream remote (one time)
git remote add upstream https://github.com/postalserver/postal.git

# Fetch upstream
git fetch upstream

# Merge upstream into main
git checkout main
git merge upstream/main

# Fix merge conflicts (will be in branded files)
# Re-apply branding changes

# Commit merge
git commit

# Tag new version based on upstream
git tag -a 3.3.5-edify.1 -m "Release 3.3.5-edify.1 - Based on Postal 3.3.5"

# Build and push
docker build -t mattbaylor/postalserver:3.3.5-edify.1 .
docker push mattbaylor/postalserver:3.3.5-edify.1
```

---

## Estimated Timeline

| Phase | Time | Notes |
|-------|------|-------|
| Git cleanup | 2 min | Quick |
| Push to GitHub | 1 min | Fast |
| Merge to main | 2 min | Simple merge |
| Create tag | 2 min | Easy |
| Docker build | 10-15 min | Longest step |
| Test image | 2 min | Quick verification |
| Push to Docker Hub | 5-10 min | Depends on connection |
| Verification | 3 min | Final checks |
| **TOTAL** | **27-37 min** | |

---

## Troubleshooting

### If force-push fails
```bash
# Someone else pushed to the branch
# Fetch and review
git fetch origin
git log origin/AmpersandUrlHandling

# If safe to overwrite, use --force
git push origin AmpersandUrlHandling --force
```

### If merge has conflicts
```bash
# Shouldn't happen since main hasn't changed
# But if it does:
git status  # See conflicted files
# Edit files to resolve
git add <resolved-files>
git commit
```

### If Docker build fails
```bash
# Check logs
docker build . 2>&1 | tee build.log

# Common issues:
# - Network timeout: retry
# - Disk space: docker system prune -a
# - Memory: increase Docker memory in settings
```

### If Docker push fails
```bash
# Re-login
docker logout
docker login

# Retry push
docker push mattbaylor/postalserver:3.3.4-edify.1
```

---

## Ready to Execute?

Copy-paste the commands from each phase in sequence. 

Start with **PHASE 1** and work through to **PHASE 8**.

Let me know when you're ready to begin, or if you have any questions!
