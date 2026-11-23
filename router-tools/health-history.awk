# Input: epoch WAN-state boot-id. Only adjacent observations establish coverage.
BEGIN { cutoff=now-86400; count=0; covered=0; since=0; previous=0 }
$1+0 > 0 && $1+0 <= now {
    t=$1+0; state=$2; boot=$3
    if (t >= cutoff && !since) since=t
    gap=t-previous
    if (previous && gap>0 && gap<=interval+15 && boot==previousboot && state!="null" && previousstate!="null") {
        start=previous<cutoff ? cutoff : previous
        if(t>start) covered+=t-start
        if(t>=cutoff && previousstate=="true" && state=="false") count++
    }
    previous=t; previousstate=state; previousboot=boot
}
END { if(!since) since=now; if(covered>86400)covered=86400; printf "%d %d %d\n",count,covered,since }
