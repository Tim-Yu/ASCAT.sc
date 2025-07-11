run_targeted_sequencing <- function(tumour_bams,
                                    bed_file,
                                    allchr=paste0("",c(1:22,"X")),
                                    sex=c("female","male","female"),
                                    chrstring_bam="",
                                    purs = seq(0.1, 1, 0.01),
                                    ploidies = seq(1.7,5, 0.01),
                                    maxtumourpsi=5,
                                    bed_padding=1000,
                                    binsize=500000,
                                    segmentation_alpha=0.01,
                                    normal_bams=NULL,
                                    nlCTS.normal=NULL,
                                    build=c("hg19","hg38",  "mm39"),
                                    predict_refit=TRUE,
                                    print_results=TRUE,
                                    MC.CORES=1,
                                    outdir="./",
                                    projectname="project",
                                    multipcf=FALSE)
{
    if(is.list(purs) & is.list(ploidies))
    {
        if(length(purs)!=length(ploidies))
            stop("purs and ploidies might not match!")
        if(length(purs)!=length(tumour_bams))
            stop("purs and bam might not match")
        if(length(ploidies)!=length(tumour_bams))
            stop("ploidies and bam might not match")
    } else if(!all(is.list(purs),is.list(ploidies))){
        stop("purs and ploidies must be both lists in the current version.")
    } else {
            purs <- lapply(1:length(bams), function(x) purs)
            ploidies <- lapply(1:length(bams), function(x) ploidies)
        }
    suppressPackageStartupMessages(require(parallel))
    suppressPackageStartupMessages(require(Rsamtools))
    suppressPackageStartupMessages(require(Biostrings))
    suppressPackageStartupMessages(require(DNAcopy))
    suppressPackageStartupMessages(require(copynumber))
    binsize <- as.numeric(binsize)
    print("## load bins for genome build")
    if(!build=="mm39") START_WINDOW <- 30000 else START_WINDOW <- 5000
    if(build=="hg19")
    {
        data("lSe_filtered_30000.hg19",package="ASCAT.sc")
        data("lGCT_filtered_30000.hg19",package="ASCAT.sc")
        allchr. <- gsub("chr","",allchr)
        lSe <- lapply(allchr., function(chr) lSe.hg19.filtered[[chr]])
        names(lSe) <- allchr
        names(lGCT.hg19.filtered) <- names(lSe)
        lGCT <- lapply(allchr, function(chr) lGCT.hg19.filtered[[chr]])
    }
    if(build=="hg38")
    {
        data("lSe_filtered_30000.hg38",package="ASCAT.sc")
        data("lGCT_filtered_30000.hg38",package="ASCAT.sc")
        lSe <- lapply(allchr, function(chr) lSe.hg38.filtered[[chr]])
        names(lSe)[1:length(allchr)] <- allchr
        names(lGCT.hg38.filtered) <- names(lSe)
        lGCT <- lapply(allchr, function(chr) lGCT.hg38.filtered[[chr]])
        names(lGCT) <- names(lSe)
        if(chrstring_bam=="")
            names(lGCT) <- names(lSe) <- gsub("chr","",names(lSe))
    }
    if(build=="mm39")
    {
        data("lSe_unfiltered_5000.mm39",package="ASCAT.sc")
        data("lGCT_unfiltered_5000.mm39",package="ASCAT.sc")
        names(lGCT)[1:length(allchr)] <- names(lSe)[1:length(allchr)] <- allchr
        lSe <- lapply(allchr,function(x) lSe[[x]])
        lGCT <- lapply(allchr,function(x) lGCT[[x]])
        names(lGCT) <- names(lSe)
    }
    print("## read in bed file")
    bed <- ts_treatBed(read.table(bed_file,
                                  sep="\t",
                                  header=F),
                       add=bed_padding)
    print("## get bin starts ends to exclude")
    lExclude <- lapply(allchr,function(chr)
        ts_getExcludeFromBedfile(bed,chr))
    names(lExclude) <- allchr
    lInds <- getlInds(lSe, lExclude)
    lGCT <- getlGCT_excluded(lGCT, lInds)
    lSe <- getlSe_excluded(lSe, lInds)
    lCTS.normal <- NULL
    lCTS.normal.combined <- NULL
    lNormals <- NULL
    timetoread_normals <- NULL
    isPON <- FALSE
    if(!is.null(normal_bams[1]) & is.null(nlCTS.normal))
    {
        print("## get all tracks from normal bams")
        timetoread_normals <- system.time(lCTS.normal <- mclapply(normal_bams,function(bamfile)
        {
            lCTS.normal <- lapply(allchr, function(chr) getCoverageTrack(bamPath=bamfile,
                                                                         chr=chr,
                                                                         lSe[[chr]]$starts,
                                                                         lSe[[chr]]$ends,
                                                                         mapqFilter=30))
            list(lCTS.normal=lCTS.normal,
                 nlCTS.normal=treatTrack(lCTS=lCTS.normal,
                                         window=ceiling(binsize/START_WINDOW)))
        },mc.cores=MC.CORES))
        lCTS.normal.combined <- combineDiploid(lapply(lCTS.normal,function(x) x[[2]]))
        isPON <- TRUE
        lNormals <- lapply(lCTS.normal,function(x) x$nlCTS.normal)
    }
    print("## calculate target bin size")
    nlGCT <- treatGCT(lGCT,window=ceiling(binsize/START_WINDOW))
    nlSe <- treatlSe(lSe,window=ceiling(binsize/START_WINDOW))
    print("## get all tracks from tumour bams")
    timetoread_tumours <- system.time(allTracks <- mclapply(tumour_bams,function(bamfile)
    {
        lCTS.tumour <- lapply(allchr, function(chr) getCoverageTrack(bamPath=bamfile,
                                                                     chr=chr,
                                                                     lSe[[chr]]$starts,
                                                                     lSe[[chr]]$ends,
                                                                     mapqFilter=30))
        list(lCTS.tumour=lCTS.tumour,
             nlCTS.tumour=treatTrack(lCTS=lCTS.tumour,
                                     window=ceiling(binsize/START_WINDOW)))
    },mc.cores=MC.CORES))
    if(multipcf)
    {
        print("## calculating multipcf - multi-sample mode - do not use if samples from different tumours")
        timetoprocessed <- system.time(
            allTracks.processed <- getLSegs.multipcf(allTracks=lapply(allTracks, function(x) {list(lCTS=x$nlCTS.tumour)}),
                                                     lCTS=lapply(allTracks,function(x) x$nlCTS.tumour),
                                                     lSe=nlSe,
                                                     lGCT=nlGCT,
                                                     lNormals=lNormals,
                                                     allchr=allchr,
                                                     segmentation_alpha=segmentation_alpha,
                                                     MC.CORES=MC.CORES))
    }
    else
    {
        print("## smooth and (apply) segments to all tracks")
        timetoprocessed <- system.time(allTracks.processed <- mclapply(1:length(allTracks), function(x)
        {
            cat(".")
            getTrackForAll(bamfile=NULL,
                           window=NULL,
                           lCT=allTracks[[x]][[2]],
                           lSe=nlSe,
                           lGCT=nlGCT,
                           lNormals=lNormals,
                           allchr=allchr,
                           sdNormalise=0,
                           segmentation_alpha=segmentation_alpha)
        },mc.cores=MC.CORES))
        cat("\n")
    }
    names(allTracks.processed) <- names(allTracks) <- gsub("(.*)/(.*)","\\2",tumour_bams)
    print("## fit purity and ploidy for all tracks")
    timetofit <- system.time(allSols <- mclapply(1:length(allTracks.processed), function(x)
    {
        sol <- try(searchGrid(allTracks.processed[[x]],
                              purs = purs[[x]],
                              ploidies = ploidies[[x]],
                              maxTumourPhi=maxtumourpsi,
                              ismale=if(sex[x]=="male") T else F,
                              isPON=isPON),silent=F)
    },mc.cores=MC.CORES))
    print("## get all fitted cna profiles")
    allProfiles <- mclapply(1:length(allTracks.processed), function(x)
    {
        try(getProfile(fitProfile(allTracks.processed[[x]],
                                  purity=allSols[[x]]$purity,
                                  ploidy=allSols[[x]]$ploidy,
                                  ismale=if(sex[x]=="male") T else F),
                       CHRS=allchr),silent=F)
    },mc.cores=MC.CORES)
    names(allProfiles) <- names(allSols) <- names(allTracks)
    print("## return all results")
    res <- list(allTracks.processed=allTracks.processed,
                allTracks=allTracks,
                allSolutions=allSols,
                allProfiles=allProfiles,
                lCTS.normal=lCTS.normal,
                nlCTS.normal=nlCTS.normal,
                chr=allchr,
                chrstring_bam=chrstring_bam,
                sex=sex,
                lSe=nlSe,
                purs=purs,
                ploidies=ploidies,
                maxtumourpsi=maxtumourpsi,
                lExclude=lExclude,
                multipcf=multipcf,
                lGCT=nlGCT,
                build=build,
                binsize=binsize,
                isPON=isPON,
                timetoread_normals=timetoread_normals,
                timetoread_tumours=timetoread_tumours,
                timetoprocessed=timetoprocessed,
                timetofit=timetofit)
    if(predict_refit)
        res <- predictRefit_all(res)
    if(print_results)
        res <- printResults_all(res, outdir=outdir, projectname=projectname)
    res
}
