# Repository Maintenance Plan - Pre Docker Hub Push

## Current State Analysis

### Repository Status
- **Current Branch:** `AmpersandUrlHandling`
- **Origin:** `https://github.com/mattbaylor/postal.git`
- **Unpushed Commits:** 4 commits ahead of `origin/AmpersandUrlHandling`
- **Stashed Changes:** 1 stash on main branch (cleanup needed)
- **Working Tree:** Clean ✓

### Branch Structure
```
* AmpersandUrlHandling (LOCAL)
  - 9dc2fb1 chore: move documentation to doc/ directory
  - 410e354 docs: add comprehensive rebranding guide
  - cf317b0 chore: complete Edify rebranding for user-facing content
  - 30d95ac fix: properly encode URLs with ampersands for IIS compatibility
  ↓
* origin/AmpersandUrlHandling (REMOTE - 4 commits behind)
  - 61a1e50 updated view to be Edify compliant
  - a396c9f Update message_parser.rb
  ↓
* main (up to date with origin)
  - da90e75 chore(main): release 3.3.4
```

### Changes Summary
- **19 files changed**
- **1,012 insertions, 24 deletions**
- **2 new documentation files** (in doc/)
- **Ampersand fix** (proper implementation)
- **Complete Edify rebrand** (all user-facing text)

---

## Maintenance Plan (Step-by-Step)

### Phase 1: Clean Up Git State

#### Step 1.1: Clear Old Stash (Optional but Recommended)
**What:** Remove the stash from main branch since we've completed the work properly
**Why:** Avoid confusion and keep repo clean

```bash
# Review what's in the stash
git stash show stash@{0}

# Drop the stash (since work is now properly committed)
git stash drop stash@{0}
```

**Risk:** Low - The stash contains our initial fix attempt which is now superseded
**Recommendation:** ✓ Do this - clean house

---

#### Step 1.2: Verify Commit Quality
**What:** Review commits for good messages and logical separation
**Why:** Good git history helps with debugging and maintenance

```bash
# Review commits
git log origin/AmpersandUrlHandling..HEAD --oneline

# Check each commit individually
git show 30d95ac --stat  # Ampersand fix
git show cf317b0 --stat  # Rebranding completion
git show 410e354 --stat  # Rebranding guide
git show 9dc2fb1 --stat  # Doc move
```

**Current Status:** ✓ Commits look good - well-organized and clear messages

---

#### Step 1.3: Consider Squashing (Optional)
**What:** Combine the 4 new commits into logical groups
**Why:** Cleaner history, easier to revert if needed

**Option A: Keep All 4 Commits (RECOMMENDED)**
```
✓ Pro: Shows progression of work
✓ Pro: Easy to cherry-pick individual changes
✗ Con: More commits
```

**Option B: Squash to 3 Commits**
```bash
# Combine ampersand fix (30d95ac) with doc move (9dc2fb1)
git rebase -i origin/AmpersandUrlHandling

# In the editor:
# pick 30d95ac fix: properly encode URLs with ampersands for IIS compatibility
# pick cf317b0 chore: complete Edify rebranding for user-facing content
# pick 410e354 docs: add comprehensive rebranding guide
# squash 9dc2fb1 chore: move documentation to doc/ directory
```

**Option C: Squash to 1 Commit**
```bash
# Create one comprehensive commit
git rebase -i origin/AmpersandUrlHandling
# Mark all but first as 'squash' or 'fixup'
```

**Recommendation:** **KEEP ALL 4 COMMITS** - they're well organized and tell a clear story

---

### Phase 2: Push to GitHub

#### Step 2.1: Review What Will Be Pushed
```bash
# See exactly what will be pushed
git diff origin/AmpersandUrlHandling..HEAD --stat

# See commit messages
git log origin/AmpersandUrlHandling..HEAD
```

---

#### Step 2.2: Push to Remote
**What:** Update the remote AmpersandUrlHandling branch
**Why:** Backs up your work, enables collaboration, prepares for Docker build

**Option A: Force Push (Required - history diverged)**
```bash
# The remote has the old broken fix, we need to replace it
git push origin AmpersandUrlHandling --force-with-lease
```

**Why force?** The remote branch has commits `61a1e50` and `a396c9f` which we've superseded with better implementations.

**What is `--force-with-lease`?**
- Safer than `--force`
- Only force-pushes if remote hasn't changed since you last fetched
- Prevents accidentally overwriting someone else's work

**Alternative: Regular Push (if remote is same as expected)**
```bash
git push origin AmpersandUrlHandling
```

**Recommendation:** ✓ Use `--force-with-lease` since history was rewritten

---

#### Step 2.3: Verify Push Succeeded
```bash
# Check branch status
git branch -vv

# Should show: [origin/AmpersandUrlHandling] (no "ahead" message)
# Fetch to confirm
git fetch origin
git log origin/AmpersandUrlHandling --oneline -5
```

---

### Phase 3: Tag Your Release

#### Step 3.1: Create a Version Tag
**What:** Tag this commit with a version number
**Why:** Makes it easy to reference, track, and deploy specific versions

```bash
# Create an annotated tag
git tag -a v1.0.0-edify -m "Edify rebrand with IIS ampersand fix

- Complete UI rebrand from Postal to Edify
- Fix URL encoding for IIS compatibility
- Add comprehensive documentation
- All user-facing text updated"

# Or create tag on specific commit
git tag -a v1.0.0-edify 9dc2fb1 -m "..."
```

**Recommended Tag Name:** `v1.0.0-edify` or `edify-2024.11.25`

---

#### Step 3.2: Push Tags to Remote
```bash
# Push specific tag
git push origin v1.0.0-edify

# Or push all tags
git push origin --tags
```

---

### Phase 4: Update Main Branch (Optional)

#### Option A: Merge to Main (For Production)
**What:** Merge AmpersandUrlHandling into main
**Why:** Makes this the "official" version

```bash
git checkout main
git merge AmpersandUrlHandling
git push origin main
```

**Considerations:**
- ✓ Makes rebrand official
- ✓ Clean main branch history
- ✗ Might want to keep Postal branding on main?

---

#### Option B: Keep Separate (For Multiple Brands)
**What:** Leave main as Postal, keep Edify on branch
**Why:** You might want to maintain both versions

**Keep As-Is:**
- `main` = Postal branded
- `AmpersandUrlHandling` = Edify branded

**Docker Strategy:**
- Build from `main` → postal-branded image
- Build from `AmpersandUrlHandling` → edify-branded image

**Recommendation:** If you want to maintain Postal version: ✓ Keep separate
If Edify is the only version you'll use: ✓ Merge to main

---

### Phase 5: Prepare for Docker Hub

#### Step 5.1: Choose Docker Tag Strategy

**For Branch-Based Build:**
```bash
# Build from branch
docker build -t yourusername/postal:edify .
docker build -t yourusername/postal:edify-v1.0.0 .
docker build -t yourusername/postal:latest .
```

**For Tag-Based Build:**
```bash
# Checkout the tag
git checkout v1.0.0-edify

# Build
docker build -t yourusername/postal:v1.0.0-edify .
docker build -t yourusername/postal:latest .
```

**Recommended Tags:**
- `yourdockerhub/postal:edify` - Latest Edify build
- `yourdockerhub/postal:edify-v1.0.0` - Specific version
- `yourdockerhub/postal:latest` - Latest build (any brand)

---

#### Step 5.2: Test Local Build First
```bash
# Build locally to verify
docker build -t postal-test:edify .

# Test the image
docker run -it postal-test:edify postal version

# Check image size
docker images | grep postal-test
```

---

#### Step 5.3: Login to Docker Hub
```bash
# Login (one time)
docker login

# Enter your Docker Hub credentials
```

---

#### Step 5.4: Build and Tag for Docker Hub
```bash
# Build with proper tags
docker build -t yourdockerhub/postal:edify-v1.0.0 .
docker build -t yourdockerhub/postal:edify .

# Verify
docker images | grep postal
```

---

#### Step 5.5: Push to Docker Hub
```bash
# Push specific version
docker push yourdockerhub/postal:edify-v1.0.0

# Push latest Edify
docker push yourdockerhub/postal:edify

# Optionally push as latest
docker push yourdockerhub/postal:latest
```

---

## Complete Checklist

### Pre-Push Checklist
- [ ] Review all 4 commits
- [ ] Verify commit messages are clear
- [ ] Check that doc/ files won't be in Docker build
- [ ] Clean up git stash
- [ ] Decide: keep commits separate or squash?
- [ ] Decide: merge to main or keep on branch?

### Git Maintenance
- [ ] Push to GitHub: `git push origin AmpersandUrlHandling --force-with-lease`
- [ ] Verify push: `git fetch && git status`
- [ ] Create tag: `git tag -a v1.0.0-edify -m "message"`
- [ ] Push tag: `git push origin v1.0.0-edify`
- [ ] (Optional) Merge to main
- [ ] Clean stash: `git stash drop stash@{0}`

### Docker Preparation
- [ ] Decide on Docker Hub username/repo name
- [ ] Login to Docker Hub: `docker login`
- [ ] Test build locally: `docker build -t postal-test:edify .`
- [ ] Verify build size and contents
- [ ] Test run: `docker run -it postal-test:edify postal version`

### Docker Hub Push
- [ ] Tag image: `docker tag postal-test:edify yourhub/postal:edify-v1.0.0`
- [ ] Push versioned: `docker push yourhub/postal:edify-v1.0.0`
- [ ] Tag latest: `docker tag postal-test:edify yourhub/postal:edify`
- [ ] Push latest: `docker push yourhub/postal:edify`

### Verification
- [ ] Check GitHub: branch updated
- [ ] Check GitHub: tags visible
- [ ] Check Docker Hub: images uploaded
- [ ] Test pull: `docker pull yourhub/postal:edify`
- [ ] Document image location for deployment

---

## Recommended Sequence

### Conservative Approach (Safest)
```bash
# 1. Clean stash
git stash drop stash@{0}

# 2. Push current work
git push origin AmpersandUrlHandling --force-with-lease

# 3. Create and push tag
git tag -a v1.0.0-edify -m "Edify rebrand with IIS fix"
git push origin v1.0.0-edify

# 4. Test Docker build locally
docker build -t postal-test:edify .
docker run -it postal-test:edify postal version

# 5. Tag for Docker Hub
docker tag postal-test:edify yourusername/postal:edify-v1.0.0
docker tag postal-test:edify yourusername/postal:edify

# 6. Push to Docker Hub
docker login
docker push yourusername/postal:edify-v1.0.0
docker push yourusername/postal:edify

# 7. Test pull
docker pull yourusername/postal:edify
```

### Time Estimate
- Git cleanup: 5 minutes
- Docker build: 10-15 minutes
- Docker push: 5-10 minutes (depending on connection)
- Total: ~30 minutes

---

## Questions to Answer Before Proceeding

1. **Do you want to merge to main?**
   - Yes → Edify becomes the official version
   - No → Keep Postal on main, Edify on branch

2. **What's your Docker Hub username?**
   - Format: `username/postal:edify`
   - Example: `mattbaylor/postal:edify`

3. **Keep commit history as-is?**
   - Yes (recommended) → 4 clear commits
   - No → Squash to fewer commits

4. **Version tag format?**
   - Semantic: `v1.0.0-edify`
   - Date-based: `edify-2024.11.25`
   - Simple: `v1.0.0`

---

## Next Steps

Once you answer the questions above, I can provide the exact commands to run in sequence.
