#!/usr/bin/env Rscript

## Emit, for every Bioconductor software package, the complete set of packages
## that must be installed so that the package and everything it declares in
## DESCRIPTION -- Depends, Imports, LinkingTo and Suggests -- can be loaded.
##
## The list is per package and deliberately not deduplicated across packages: a
## dependency shared by fifty packages appears in all fifty lists, because each
## one becomes its own container image.
##
## Usage:
##   Rscript bioc_pkgs.R [--outdir=DIR] [--repos=BioCsoft,BioCann]
##                       [--which=most] [--pkgs=A,B,C]
##
##   --outdir  directory for the generated manifest (default "manifest")
##   --repos   Bioconductor repositories whose packages get a manifest entry
##             (default BioCsoft).  Dependencies are always resolved against
##             every repository BiocManager knows about, plus CRAN.
##   --which   DESCRIPTION fields to read for the target package itself
##             (default "most" = Depends, Imports, LinkingTo, Suggests).
##   --pkgs    restrict the run to these packages, for testing.

options(warn = 1L)

if (!requireNamespace("BiocManager", quietly = TRUE))
    install.packages("BiocManager", repos = "https://cloud.r-project.org")
if (!requireNamespace("jsonlite", quietly = TRUE))
    install.packages("jsonlite", repos = "https://cloud.r-project.org")

## ---------------------------------------------------------------- arguments

.parse_args <- function(args = commandArgs(trailingOnly = TRUE)) {
    keyed <- grepl("^--[^=]+=", args)
    if (!all(keyed))
        stop("unrecognised argument(s): ", paste(args[!keyed], collapse = ", "))
    values <- sub("^--[^=]+=", "", args)
    names(values) <- sub("^--([^=]+)=.*$", "\\1", args)
    as.list(values)
}

.split_arg <- function(x)
    if (is.null(x)) NULL else trimws(strsplit(x, ",", fixed = TRUE)[[1L]])

args <- .parse_args()
outdir <- if (is.null(args$outdir)) "manifest" else args$outdir
target_repos <- if (is.null(args$repos)) "BioCsoft" else .split_arg(args$repos)
which_fields <- if (is.null(args$which)) "most" else args$which
pkg_subset <- .split_arg(args$pkgs)

dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(outdir, "pkglists"), recursive = TRUE, showWarnings = FALSE)

## ------------------------------------------------------------- environment

repos <- BiocManager::repositories()
bioc_version <- as.character(BiocManager::version())
r_version <- paste(R.version$major, R.version$minor, sep = ".")

message("Bioconductor ", bioc_version, " on R ", r_version)
message("repositories:\n  ", paste(names(repos), repos, sep = ": ",
                                   collapse = "\n  "))

## Packages shipped with R itself are always present and are never installed.
## Recommended packages are deliberately *not* excluded: they are guaranteed in
## the Bioconductor image but not in every bioc2u base.
.base_packages <- function() {
    inst <- installed.packages()
    unname(inst[inst[, "Priority"] %in% "base", "Package"])
}
exclude <- .base_packages()

## --------------------------------------------------------------- available

db <- available.packages(repos = repos)

.pkgs_in <- function(repo_names) {
    known <- intersect(repo_names, names(repos))
    if (!length(known))
        stop("unknown repository/repositories: ",
             paste(setdiff(repo_names, names(repos)), collapse = ", "))
    unname(available.packages(repos = repos[known])[, "Package"])
}

bioc_repo_names <- grep("^BioC", names(repos), value = TRUE)
bioc_pkgs <- .pkgs_in(bioc_repo_names)

targets <- sort(unique(.pkgs_in(target_repos)))
if (!is.null(pkg_subset)) {
    missing_subset <- setdiff(pkg_subset, targets)
    if (length(missing_subset))
        stop("--pkgs names packages absent from --repos: ",
             paste(missing_subset, collapse = ", "))
    targets <- sort(pkg_subset)
}
message("target packages: ", length(targets))

## Image names are lowercased for the registry, so the mapping has to stay
## injective.  It is today; fail loudly rather than silently overwrite a tag if
## Bioconductor ever accepts two packages differing only in case.
collisions <- unique(tolower(targets)[duplicated(tolower(targets))])
if (length(collisions))
    stop("package names collide when lowercased for the registry: ",
         paste(vapply(collisions, function(lc)
             paste(grep(lc, targets, ignore.case = TRUE, value = TRUE),
                   collapse = " / "), character(1L)), collapse = "; "))

## ------------------------------------------------------------ dependencies

## which = "most" reads Depends, Imports, LinkingTo and Suggests off the target
## package; recursive = "strong" then follows only Depends/Imports/LinkingTo
## down the tree.  That is exactly what has to be installed for the package and
## its suggested packages to load -- suggests-of-suggests are not required.
message("resolving dependencies (which = ", which_fields,
        ", recursive = strong) ...")
deps <- tools::package_dependencies(targets, db = db, which = which_fields,
                                    recursive = "strong")

## Anything a package declares that is neither a base package nor available from
## CRAN or Bioconductor (GitHub-only packages, mostly) cannot be installed, and
## is reported instead of silently disappearing.
declared <- tools::package_dependencies(targets, db = db, which = which_fields,
                                        recursive = FALSE)
installable <- c(rownames(db), exclude)

known_bioc <- bioc_pkgs
manifest <- vector("list", length(targets))
names(manifest) <- targets

## package_dependencies() echoes back whatever the target package declares, even
## when the named package is not in any configured repository (archived on CRAN,
## deprecated out of Bioconductor).  Those cannot be installed, so they are kept
## out of the install list and surfaced under `unresolved` instead.
for (pkg in targets) {
    install <- intersect(unique(c(deps[[pkg]], pkg)), rownames(db))
    install <- sort(setdiff(install, exclude))
    from_bioc <- intersect(install, known_bioc)
    manifest[[pkg]] <- list(
        package = jsonlite::unbox(pkg),
        image = jsonlite::unbox(tolower(pkg)),
        version = jsonlite::unbox(unname(db[pkg, "Version"])),
        bioc_version = jsonlite::unbox(bioc_version),
        r_version = jsonlite::unbox(r_version),
        n_install = jsonlite::unbox(length(install)),
        install = install,
        bioc = from_bioc,
        cran = setdiff(install, from_bioc),
        unresolved = sort(setdiff(declared[[pkg]], installable))
    )
    writeLines(install, file.path(outdir, "pkglists", paste0(pkg, ".txt")))
}

## ------------------------------------------------------------------ output

writeLines(targets, file.path(outdir, "packages.txt"))
writeLines(bioc_version, file.path(outdir, "bioc_version"))
writeLines(r_version, file.path(outdir, "r_version"))

json <- jsonlite::toJSON(manifest, pretty = TRUE, auto_unbox = FALSE)
writeLines(json, file.path(outdir, "manifest.json"))

summary_df <- data.frame(
    package = targets,
    image = tolower(targets),
    version = vapply(manifest, function(x) as.character(x$version), character(1L)),
    n_install = vapply(manifest, function(x) as.integer(x$n_install), integer(1L)),
    n_bioc = vapply(manifest, function(x) length(x$bioc), integer(1L)),
    n_cran = vapply(manifest, function(x) length(x$cran), integer(1L)),
    n_unresolved = vapply(manifest, function(x) length(x$unresolved), integer(1L)),
    row.names = NULL, stringsAsFactors = FALSE
)
write.csv(summary_df, file.path(outdir, "summary.csv"), row.names = FALSE)

unresolved <- sort(unique(unlist(lapply(manifest, `[[`, "unresolved"))))
writeLines(unresolved, file.path(outdir, "unresolved.txt"))

message("wrote ", outdir, "/manifest.json for ", length(targets), " packages")
message("packages to install per image: min ", min(summary_df$n_install),
        ", median ", stats::median(summary_df$n_install),
        ", max ", max(summary_df$n_install))
if (length(unresolved))
    message(length(unresolved), " suggested package(s) are on neither CRAN nor ",
            "Bioconductor and were dropped; see ", outdir, "/unresolved.txt")
