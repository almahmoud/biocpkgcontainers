#!/usr/bin/env Rscript

## Install a newline-delimited list of packages and prove that every one of them
## landed.  This runs unmodified on both bases: on ghcr.io/bioconductor/bioconductor
## BiocManager pulls from the Bioconductor binary repositories, and on
## ghcr.io/bioconductor/bioc2u-user bspm transparently redirects the same calls
## at the bioc2u/r2u apt binaries.  Nothing here knows or cares which one it is.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L)
    stop("usage: install.R <pkgs.txt>")

pkg_file <- args[[1L]]
package <- Sys.getenv("PACKAGE", NA_character_)
strict <- !identical(Sys.getenv("STRICT", "1"), "0")
report_dir <- Sys.getenv("REPORT_DIR", "/usr/local/share/biocpkgcontainers")

ncpus <- suppressWarnings(as.integer(Sys.getenv("NCPUS", "")))
if (is.na(ncpus) || ncpus < 1L)
    ncpus <- max(1L, parallel::detectCores(logical = TRUE))

options(
    warn = 1L,
    Ncpus = ncpus,
    ## Annotation and experiment packages run to hundreds of megabytes; the 60s
    ## default aborts those downloads mid-flight.
    timeout = max(3600L, getOption("timeout")),
    install.packages.check.source = "no",
    repos = BiocManager::repositories()
)
Sys.setenv(DEBIAN_FRONTEND = "noninteractive")

wanted <- unique(trimws(readLines(pkg_file, warn = FALSE)))
wanted <- wanted[nzchar(wanted)]
if (!length(wanted))
    stop("no packages listed in ", pkg_file)

.installed <- function() rownames(installed.packages())

message("=== biocpkgcontainers ===")
message("target package : ", if (is.na(package)) "<unset>" else package)
message("R              : ", getRversion())
message("Bioconductor   : ", as.character(BiocManager::version()))
message("bspm active    : ", "bspm" %in% .installed())
message("requested      : ", length(wanted), " packages")
message("Ncpus          : ", ncpus)

todo <- setdiff(wanted, .installed())
message("already present: ", length(wanted) - length(todo))
message("to install     : ", length(todo))

if (length(todo)) {
    ## One bulk call first: it lets the backend resolve and fetch everything in
    ## parallel, which is where nearly all of the wall-clock time goes.
    ## install.packages() warns rather than errors on individual failures, so the
    ## authoritative check is the verification pass below, not this call.
    try(BiocManager::install(todo, ask = FALSE, update = FALSE,
                             checkBuilt = FALSE), silent = FALSE)

    ## Anything still missing gets a second, isolated attempt.  A package that
    ## failed only because a sibling in the same batch blew up will succeed here.
    missing <- setdiff(wanted, .installed())
    if (length(missing)) {
        message("retrying ", length(missing), " package(s) individually ...")
        for (p in missing) {
            message("--- retry: ", p)
            try(BiocManager::install(p, ask = FALSE, update = FALSE,
                                     checkBuilt = FALSE), silent = FALSE)
        }
    }
}

## ------------------------------------------------------------ verification

have <- .installed()
missing <- setdiff(wanted, have)
present <- intersect(wanted, have)

dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
writeLines(wanted, file.path(report_dir, "requested.txt"))
writeLines(missing, file.path(report_dir, "missing.txt"))

ip <- installed.packages()
versions <- data.frame(package = present,
                       version = unname(ip[present, "Version"]),
                       row.names = NULL, stringsAsFactors = FALSE)
write.table(versions, file.path(report_dir, "installed.tsv"), sep = "\t",
            quote = FALSE, row.names = FALSE)

message("=== result ===")
message("installed: ", length(present), "/", length(wanted))
if (length(missing)) {
    message("MISSING (", length(missing), "): ", paste(missing, collapse = ", "))
    if (strict)
        stop("failed to install ", length(missing), " of ", length(wanted),
             " requested packages; set STRICT=0 to build anyway")
} else {
    message("all requested packages installed")
}
