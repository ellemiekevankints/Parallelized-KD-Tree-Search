#include "KDTree.cuh"

/******************
* KD TREE METHODS *
*******************/

template<typename T>
ssrlcv::KDTree<T>::KDTree() {}

template<typename T>
ssrlcv::KDTree<T>::KDTree(ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<T>>> _points) {
    build(_points);
}

template<typename T>
ssrlcv::KDTree<T>::KDTree(ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<T>>> _points, vector<T> _labels) {
    build(_points, _labels);
}

struct SubTree {
    SubTree() : first(0), last(0), nodeIdx(0), depth(0) {}
    SubTree(int _first, int _last, int _nodeIdx, int _depth)
        : first(_first), last(_last), nodeIdx(_nodeIdx), depth(_depth) {}
    int first;
    int last;
    int nodeIdx;
    int depth;
};

static float medianPartition(size_t* ofs, int a, int b, const unsigned char* vals) {
    int k, a0 = a, b0 = b;
    int middle = (a + b)/2;
    while( b > a ) {
        int i0 = a, i1 = (a+b)/2, i2 = b;
        float v0 = vals[ofs[i0]], v1 = vals[ofs[i1]], v2 = vals[ofs[i2]];
        int ip = v0 < v1 ? (v1 < v2 ? i1 : v0 < v2 ? i2 : i0) :
                 v0 < v2 ? (v1 == v0 ? i2 : i0): (v1 < v2 ? i2 : i1);
        float pivot = vals[ofs[ip]];
        swap(ofs[ip], ofs[i2]);

        for( i1 = i0, i0--; i1 <= i2; i1++ ) {
            if( vals[ofs[i1]] <= pivot ) {
                i0++; 
                swap(ofs[i0], ofs[i1]);
            }
        } // for
        if( i0 == middle )
            break;
        if( i0 > middle )
            b = i0 - (b == i0);
        else
            a = i0;
    } // while

    float pivot = vals[ofs[middle]];
    for( k = a0; k < middle; k++ ) {
        if( !(vals[ofs[k]] <= pivot) ) {
           logger.err<<"ERROR: median partition unsuccessful"<<"\n"; 
        }
    }
    for( k = b0; k > middle; k-- ) {
       if( !(vals[ofs[k]] >= pivot) ) {
           logger.err<<"ERROR: median partition unsuccessful"<<"\n"; 
        } 
    }

    return vals[ofs[middle]];
} // medianPartition

template<typename T>
static void computeSums(ssrlcv::Feature<T>* points, int start, int end, unsigned char *sums) {
   
    int i, j, dims = K; 
    ssrlcv::Feature<T> data; 

    // initilize sums array with 0
    for(j = 0; j < dims; j++)
        sums[j*2] = sums[j*2+1] = 0;

    // compute the square of each element in the values array 
    for(i = start; i <= end; i++) {
        data = points[i];
        for(j = 0; j < dims; j++) {
            double t = data.descriptor.values[j], s = sums[j*2] + t, s2 = sums[j*2+1] + t*t;
            sums[j*2] = s; sums[j*2+1] = s2;
        }
    }
} // computeSums

template<typename T>
void ssrlcv::KDTree<T>::build(ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<T>>> _points) {
    vector<int> labels;
    build(_points, labels);
} // build

template<typename T>
void ssrlcv::KDTree<T>::build(ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<T>>> _points, vector<int> _labels) {

    if (_points->size() == 0) {
        logger.err<<"ERROR: number of features in image must be greater than zero"<<"\n";
    }
    
    // initilize nodes of KD Tree
    nodes.clear();
    nodes.shrink_to_fit();
    points = _points;

    int i, j, n = _points->size(), top = 0;
    const unsigned char* data = _points->host->descriptor.values;
    unsigned char* dstdata = points->host->descriptor.values;

    // size of object in memory 
    size_t step = sizeof(ssrlcv::Feature<T>);

    labels.resize(n); // labels and points array will share same size 
    const int* _labels_data = 0;

    if( !_labels.empty() ) {
        int nlabels = n*K;
        if ( !(nlabels==n) ) {
            logger.err<<"ERROR: labels size must be equal to points size"<<"\n";
        } 
        _labels_data = _labels.data(); 
    }

    // will hold the SIFT_Descriptor values array AND its squares
    unsigned char sumstack[MAX_TREE_DEPTH*2][K*2];
    SubTree stack[MAX_TREE_DEPTH*2]; 

    vector<size_t> _ptofs(n);
    size_t* ptofs = &_ptofs[0];

    for (i = 0; i < n; i++) { 
        ptofs[i] = i*step;
    }

    nodes.push_back(Node());
    computeSums<T>(points->host.get(), 0, n-1, sumstack[top]);
    stack[top++] = SubTree(0, n-1, 0, 0);
    int _maxDepth = 0;

    while (--top >= 0) {
        int first = stack[top].first, last = stack[top].last;
        int depth = stack[top].depth, nidx = stack[top].nodeIdx;
        int count = last - first + 1, dim = -1;
        const unsigned char* sums = sumstack[top]; // points to the first element in uchar array
        double invCount = 1./count, maxVar = -1.;

        if (count == 1) {
            int idx0 = (int)(ptofs[first]/step);
            int idx = idx0; // the dimension
            nodes[nidx].idx = ~idx;
            
            labels[idx] = _labels_data ? _labels_data[idx0] : idx0;
            _maxDepth = std::max(_maxDepth, depth);
            continue;
        }

        // find the dimensionality with the biggest variance
        for ( j = 0; j < K; j++ ) {
            unsigned char m = sums[j*2]*invCount;
            unsigned char varj = sums[j*2+1]*invCount - m*m;
            if ( maxVar < varj ) {
                maxVar = varj;
                dim = j;
            }
        }

        int left = (int)nodes.size(), right = left + 1;
        nodes.push_back(Node());
        nodes.push_back(Node());
        nodes[nidx].idx = dim;
        nodes[nidx].left = left;
        nodes[nidx].right = right;
        nodes[nidx].boundary = medianPartition(ptofs, first, last, data + dim);

        int middle = (first + last)/2;
        unsigned char* lsums = (unsigned char*)sums, *rsums = lsums + K*2;
        computeSums(points->host.get(), middle+1, last, rsums);

        for (j = 0; j < K*2; j++) {
            lsums[j] = sums[j] - rsums[j];
        }
        stack[top++] = SubTree(first, middle, left, depth+1);
        stack[top++] = SubTree(middle+1, last, right, depth+1);
    } // while
    maxDepth = _maxDepth;
} // build

// The below algorithm is from:
// J.S. Beis and D.G. Lowe. Shape Indexing Using Approximate Nearest-Neighbor Search
// in High-Dimensional Spaces. In Proc. IEEE Conf. Comp. Vision Patt. Recog.,
// pages 1000--1006, 1997. https://www.cs.ubc.ca/~lowe/papers/cvpr97.pdf
template<typename T> 
__device__ ssrlcv::DMatch ssrlcv::findNearest(ssrlcv::KDTree<T>* kdtree, typename KDTree<T>::Node* nodes, ssrlcv::Feature<T>* featuresTree,
ssrlcv::Feature<T> feature, int emax, float absoluteThreshold, int k) {

    T desc = feature.descriptor;
    const unsigned char *vec = desc.values; // descriptor values[128] from query

    int i, j, ncount = 0, e = 0;
    int qsize = 0;
    const int maxqsize = 1 << 10;

    int idx[2]; // holds the node indices
    float dist[2]; // holds the euclidean distances

    ssrlcv::PQueueElem pqueue[maxqsize]; // priority queue to search the search

    for (e = 0; e < emax;) {
        float d, alt_d = 0.f; 
        int nidx; // node index
        
        if (e == 0) { nidx = 0; } 
        else {
            // take the next node from the priority queue
            if (qsize == 0) { break; }
            nidx = pqueue[0].idx; // current tree position
            alt_d = pqueue[0].dist; // distance of the query point from the node
            
            if (--qsize > 0) {
                
                // std::swap(pqueue[0], pqueue[qsize]);
                ssrlcv::PQueueElem temp = pqueue[0];
                pqueue[0] = pqueue[qsize];
                pqueue[qsize] = temp; 

                d = pqueue[0].dist;
                for (i = 0;;) {
                    int left = i*2 + 1, right = i*2 + 2;
                    if (left >= qsize)
                        break;
                    if (right < qsize && pqueue[right].dist < pqueue[left].dist)
                        left = right;
                    if (pqueue[left].dist >= d)
                        break;
                    
                    // std::swap(pqueue[i], pqueue[left]);
                    ssrlcv::PQueueElem temp = pqueue[i];
                    pqueue[i] = pqueue[left];
                    pqueue[left] = temp;

                    i = left;
                } // for
            } // if
            if (ncount == k && alt_d > dist[ncount-1]) { continue; }
        } // if-else

        for (;;) {
            if (nidx < 0) 
                break;
                
            const typename KDTree<T>::Node& n = nodes[nidx];

            if (n.idx < 0) { // if it is a leaf node
                i = ~n.idx; 
                const unsigned char* row = featuresTree[i].descriptor.values; // descriptor values[128] from tree

                // euclidean distance
                for (j = 0, d = 0.f; j < K; j++) {
                    float t = vec[j] - row[j];
                    d += t*t;
                }
                dist[ncount] = d;
                //printf("\nthreadIdx[%d] dist[%d] = %f\n", threadIdx.x, ncount, dist[ncount]);
                idx[ncount] = i;
                //printf("\nthreadIdx[%d] idx[%d] = %f\n", threadIdx.x, ncount, idx[ncount]);

                for (i = ncount-1; i >= 0; i--) {
                    if (dist[i] <= d)
                        break;
                    // std::swap(dist[i], dist[i+1]);
                    float dtemp = dist[i];
                    dist[i] = dist[i+1];
                    dist[i+1] = dtemp;
                    // std::swap(idx[i], idx[i+1]);
                    int itemp = idx[i];
                    idx[i] = idx[i+1];
                    idx[i+1] = itemp; 
                } // for
                ncount += ncount < k;
                e++;
                break; 

            } // if

            int alt;
            if (vec[n.idx] <= n.boundary) {
                nidx = n.left;
                alt = n.right;
            } else {
                nidx = n.right;
                alt = n.left;
            }

            d = vec[n.idx] - n.boundary;
            d = d*d + alt_d; // euclidean distance

            // subtree prunning
            if (ncount == k && d > dist[ncount-1])
                continue;
            // add alternative subtree to the priority queue
            pqueue[qsize] = PQueueElem(d, alt);
            for (i = qsize; i > 0;) {
                int parent = (i-1)/2;
                if (parent < 0 || pqueue[parent].dist <= d)
                    break;

                // std::swap(pqueue[i], pqueue[parent]);
                ssrlcv::PQueueElem temp = pqueue[i];
                pqueue[i] = pqueue[parent];
                pqueue[parent] = temp; 

                i = parent;
            } // for
            qsize += qsize+1 < maxqsize;
        } // for
    } // for
    
    DMatch match;
    match.distance = dist[0]; // smallest distance
    int matchIndex = idx[0]; // index of corresponding leaf node/point

    if (match.distance >= absoluteThreshold) { match.invalid = true; } 
    else {
      match.invalid = false;
      match.keyPoints[0].loc = featuresTree[matchIndex].loc; // img1, kdtree features
      match.keyPoints[1].loc = feature.loc; // img2, query features
      
      // we do not have Image class implemented so no image id
      // match.keyPoints[0].parentId = queryImageID;  
      // match.keyPoints[1].parentId = targetImageID;
    }

    return match;
} // findNearest

// The below algorithm is from:
// J.S. Beis and D.G. Lowe. Shape Indexing Using Approximate Nearest-Neighbor Search
// in High-Dimensional Spaces. In Proc. IEEE Conf. Comp. Vision Patt. Recog.,
// pages 1000--1006, 1997. https://www.cs.ubc.ca/~lowe/papers/cvpr97.pdf
template<typename T> 
__device__ ssrlcv::DMatch ssrlcv::findNearest(ssrlcv::KDTree<T>* kdtree, typename KDTree<T>::Node* nodes, ssrlcv::Feature<T>* featuresTree,
ssrlcv::Feature<T> feature, int emax, float relativeThreshold, float absoluteThreshold, float nearestSeed, int k) {

    T desc = feature.descriptor;
    const unsigned char *vec = desc.values; // descriptor values[128] from query

    int i, j, ncount = 0, e = 0;
    int qsize = 0;
    const int maxqsize = 1 << 10;

    int idx[2]; // holds the node indices
    float dist[2]; // holds the euclidean distances

    ssrlcv::PQueueElem pqueue[maxqsize]; // priority queue to search the search

    for (e = 0; e < emax;) {
        float d, alt_d = 0.f; 
        int nidx; // node index
        
        if (e == 0) { nidx = 0; } 
        else {
            // take the next node from the priority queue
            if (qsize == 0) { break; }
            nidx = pqueue[0].idx; // current tree position
            alt_d = pqueue[0].dist; // distance of the query point from the node
            
            if (--qsize > 0) {
                
                // std::swap(pqueue[0], pqueue[qsize]);
                ssrlcv::PQueueElem temp = pqueue[0];
                pqueue[0] = pqueue[qsize];
                pqueue[qsize] = temp; 

                d = pqueue[0].dist;
                for (i = 0;;) {
                    int left = i*2 + 1, right = i*2 + 2;
                    if (left >= qsize)
                        break;
                    if (right < qsize && pqueue[right].dist < pqueue[left].dist)
                        left = right;
                    if (pqueue[left].dist >= d)
                        break;
                    
                    // std::swap(pqueue[i], pqueue[left]);
                    ssrlcv::PQueueElem temp = pqueue[i];
                    pqueue[i] = pqueue[left];
                    pqueue[left] = temp;

                    i = left;
                } // for
            } // if
            if (ncount == k && alt_d > dist[ncount-1]) { continue; }
        } // if-else

        for (;;) {
            if (nidx < 0) 
                break;
                
            const typename KDTree<T>::Node& n = nodes[nidx];

            if (n.idx < 0) { // if it is a leaf node
                i = ~n.idx; 
                const unsigned char* row = featuresTree[i].descriptor.values; // descriptor values[128] from tree

                // euclidean distance
                for (j = 0, d = 0.f; j < K; j++) {
                    float t = vec[j] - row[j];
                    d += t*t;
                }
                dist[ncount] = d;
                //printf("\nthreadIdx[%d] dist[%d] = %f\n", threadIdx.x, ncount, dist[ncount]);
                idx[ncount] = i;
                //printf("\nthreadIdx[%d] idx[%d] = %f\n", threadIdx.x, ncount, idx[ncount]);

                for (i = ncount-1; i >= 0; i--) {
                    if (dist[i] <= d)
                        break;
                    // std::swap(dist[i], dist[i+1]);
                    float dtemp = dist[i];
                    dist[i] = dist[i+1];
                    dist[i+1] = dtemp;
                    // std::swap(idx[i], idx[i+1]);
                    int itemp = idx[i];
                    idx[i] = idx[i+1];
                    idx[i+1] = itemp; 
                } // for
                ncount += ncount < k;
                e++;
                break; 

            } // if

            int alt;
            if (vec[n.idx] <= n.boundary) {
                nidx = n.left;
                alt = n.right;
            } else {
                nidx = n.right;
                alt = n.left;
            }

            d = vec[n.idx] - n.boundary;
            d = d*d + alt_d; // euclidean distance

            // subtree prunning
            if (ncount == k && d > dist[ncount-1])
                continue;
            // add alternative subtree to the priority queue
            pqueue[qsize] = PQueueElem(d, alt);
            for (i = qsize; i > 0;) {
                int parent = (i-1)/2;
                if (parent < 0 || pqueue[parent].dist <= d)
                    break;

                // std::swap(pqueue[i], pqueue[parent]);
                ssrlcv::PQueueElem temp = pqueue[i];
                pqueue[i] = pqueue[parent];
                pqueue[parent] = temp; 

                i = parent;
            } // for
            qsize += qsize+1 < maxqsize;
        } // for
    } // for

    DMatch match;
    match.distance = dist[0]; // smallest distance
    int matchIndex = idx[0]; // index of corresponding leaf node/point

    if (match.distance >= absoluteThreshold) {
        match.invalid = true; 
    } else { 
      if (match.distance/nearestSeed > relativeThreshold*relativeThreshold) {
        match.invalid = true;
      } else {
        match.invalid = false;
        match.keyPoints[0].loc = featuresTree[matchIndex].loc; // img1, kdtree features
        printf("\nwith seed image: (%f, %f)\n", match.keyPoints[0].loc.x, match.keyPoints[0].loc.y);
        match.keyPoints[1].loc = feature.loc; // img2, query features
      
        // we do not have Image class implemented so no image id
        // match.keyPoints[0].parentId = queryImageID;  
        // match.keyPoints[1].parentId = targetImageID;
      } 
    } // if-else

    return match;
} // findNearest

/***********************************************
* SEED FEATURE STUFF THAT BELONGS IN KDTREE.CU *
************************************************/

// The below algorithm is from:
// J.S. Beis and D.G. Lowe. Shape Indexing Using Approximate Nearest-Neighbor Search
// in High-Dimensional Spaces. In Proc. IEEE Conf. Comp. Vision Patt. Recog.,
// pages 1000--1006, 1997. https://www.cs.ubc.ca/~lowe/papers/cvpr97.pdf
template<typename T> 
__device__ float ssrlcv::findNearest(ssrlcv::KDTree<T>* kdtree, typename KDTree<T>::Node* nodes, ssrlcv::Feature<T>* featuresTree,
ssrlcv::Feature<T> feature, int emax, int k) {

    T desc = feature.descriptor;
    const unsigned char *vec = desc.values; // descriptor values[128] from query

    int i, j, ncount = 0, e = 0;
    int qsize = 0;
    const int maxqsize = 1 << 10;

    int idx[2]; // holds the node indices
    float dist[2]; // holds the euclidean distances

    ssrlcv::PQueueElem pqueue[maxqsize]; // priority queue to search the search

    for (e = 0; e < emax;) {
        float d, alt_d = 0.f; 
        int nidx; // node index
        
        if (e == 0) { nidx = 0; } 
        else {
            // take the next node from the priority queue
            if (qsize == 0) { break; }
            nidx = pqueue[0].idx; // current tree position
            alt_d = pqueue[0].dist; // distance of the query point from the node
            
            if (--qsize > 0) {
                
                // std::swap(pqueue[0], pqueue[qsize]);
                ssrlcv::PQueueElem temp = pqueue[0];
                pqueue[0] = pqueue[qsize];
                pqueue[qsize] = temp; 

                d = pqueue[0].dist;
                for (i = 0;;) {
                    int left = i*2 + 1, right = i*2 + 2;
                    if (left >= qsize)
                        break;
                    if (right < qsize && pqueue[right].dist < pqueue[left].dist)
                        left = right;
                    if (pqueue[left].dist >= d)
                        break;
                    
                    // std::swap(pqueue[i], pqueue[left]);
                    ssrlcv::PQueueElem temp = pqueue[i];
                    pqueue[i] = pqueue[left];
                    pqueue[left] = temp;

                    i = left;
                } // for
            } // if
            if (ncount == k && alt_d > dist[ncount-1]) { continue; }
        } // if-else

        for (;;) {
            if (nidx < 0) 
                break;
                
            const typename KDTree<T>::Node& n = nodes[nidx];

            if (n.idx < 0) { // if it is a leaf node
                i = ~n.idx; 
                const unsigned char* row = featuresTree[i].descriptor.values; // descriptor values[128] from tree

                // euclidean distance
                for (j = 0, d = 0.f; j < K; j++) {
                    float t = vec[j] - row[j];
                    d += t*t;
                }
                dist[ncount] = d;
                //printf("\nthreadIdx[%d] dist[%d] = %f\n", threadIdx.x, ncount, dist[ncount]);
                idx[ncount] = i;
                //printf("\nthreadIdx[%d] idx[%d] = %f\n", threadIdx.x, ncount, idx[ncount]);

                for (i = ncount-1; i >= 0; i--) {
                    if (dist[i] <= d)
                        break;
                    // std::swap(dist[i], dist[i+1]);
                    float dtemp = dist[i];
                    dist[i] = dist[i+1];
                    dist[i+1] = dtemp;
                    // std::swap(idx[i], idx[i+1]);
                    int itemp = idx[i];
                    idx[i] = idx[i+1];
                    idx[i+1] = itemp; 
                } // for
                ncount += ncount < k;
                e++;
                break; 

            } // if

            int alt;
            if (vec[n.idx] <= n.boundary) {
                nidx = n.left;
                alt = n.right;
            } else {
                nidx = n.right;
                alt = n.left;
            }

            d = vec[n.idx] - n.boundary;
            d = d*d + alt_d; // euclidean distance

            // subtree prunning
            if (ncount == k && d > dist[ncount-1])
                continue;
            // add alternative subtree to the priority queue
            pqueue[qsize] = PQueueElem(d, alt);
            for (i = qsize; i > 0;) {
                int parent = (i-1)/2;
                if (parent < 0 || pqueue[parent].dist <= d)
                    break;

                // std::swap(pqueue[i], pqueue[parent]);
                ssrlcv::PQueueElem temp = pqueue[i];
                pqueue[i] = pqueue[parent];
                pqueue[parent] = temp; 

                i = parent;
            } // for
            qsize += qsize+1 < maxqsize;
        } // for
    } // for
    
    return dist[0];
} // findNearestSeed

/* ************************************************************************************************************************************************************************************************************************************************************************** */

template<typename T>
ssrlcv::MatchFactory<T>::MatchFactory(float relativeThreshold, float absoluteThreshold) :
relativeThreshold(relativeThreshold), absoluteThreshold(absoluteThreshold)
{
  this->seedFeatures = nullptr;
}

template<typename T>
void ssrlcv::MatchFactory<T>::setSeedFeatures(ssrlcv::ptr::value<Unity<Feature<T>>> seedFeatures){
  this->seedFeatures = seedFeatures;
}

template<typename T>
void ssrlcv::MatchFactory<T>::validateMatches(ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::DMatch>> matches) {
  MemoryState origin = matches->getMemoryState();
  if (origin != gpu) matches->setMemoryState(gpu);
  
  thrust::device_ptr<DMatch> needsValidating(matches->device.get());
  thrust::device_ptr<DMatch> new_end = thrust::remove_if(needsValidating,needsValidating+matches->size(),validate());
  cudaDeviceSynchronize();
  CudaCheckError();
  int numMatchesLeft = new_end - needsValidating;
  if (numMatchesLeft == 0) {
    std::cout<<"No valid matches found"<<"\n";
    matches.clear();
    return;
  } // if
  
  printf("%d valid matches found out of %lu original matches\n",numMatchesLeft,matches->size());

  ssrlcv::ptr::device<DMatch> validatedMatches_device(numMatchesLeft);
  CudaSafeCall(cudaMemcpy(validatedMatches_device.get(),matches->device.get(),numMatchesLeft*sizeof(DMatch),cudaMemcpyDeviceToDevice));

  matches->setData(validatedMatches_device,numMatchesLeft,gpu);

  if (origin != gpu) matches->setMemoryState(origin);
} // validateMatches

template<typename T>
ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::DMatch>> ssrlcv::MatchFactory<T>::generateDistanceMatches(int queryID, ssrlcv::ptr::value<ssrlcv::Unity<Feature<T>>> queryFeatures, int targetID, ssrlcv::KDTree<T> kdtree, ssrlcv::ptr::value<ssrlcv::Unity<float>> seedDistances) {

  // transfer query points to GPU
  MemoryState q_origin = queryFeatures->getMemoryState();
  if(q_origin != gpu) queryFeatures->setMemoryState(gpu);

  // transfer KD-Tree to GPU
  ssrlcv::ptr::device<ssrlcv::KDTree<T>> d_kdtree(1); 
  CudaSafeCall(cudaMemcpy(d_kdtree.get(),&kdtree,sizeof(kdtree),cudaMemcpyHostToDevice));
   
  // transfer KD-Tree nodes to GPU
  thrust::device_vector<typename KDTree<T>::Node> d_nodes = kdtree.nodes;
  typename KDTree<T>::Node* pd_nodes = thrust::raw_pointer_cast(d_nodes.data());

  // transfer KD-Tree points to GPU
  ssrlcv::ptr::value<ssrlcv::Unity<Feature<T>>> d_points = kdtree.points; 
  MemoryState t_origin = d_points->getMemoryState();
  if(t_origin != gpu) d_points->setMemoryState(gpu); 

  // array to hold the matched pairs
  unsigned int numPossibleMatches = queryFeatures->size();
  ssrlcv::ptr::value<ssrlcv::Unity<DMatch>> matches = ssrlcv::ptr::value<ssrlcv::Unity<DMatch>>(nullptr, numPossibleMatches, gpu);

  // grid and block initilization
  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};
  void (*ptr)(unsigned int, unsigned long, Feature<T>*, unsigned int, KDTree<T>*,
  typename KDTree<T>::Node*, Feature<T>*, DMatch*, float) = &matchFeaturesKDTree;
  getFlatGridBlock(queryFeatures->size(), grid, block, ptr);

  clock_t timer = clock();
  
  if (seedDistances == nullptr) {
    matchFeaturesKDTree<T><<<grid, block>>>(queryID, queryFeatures->size(), queryFeatures->device.get(), 
    targetID, d_kdtree.get(), pd_nodes, d_points->device.get(), matches->device.get(), this->absoluteThreshold);
  } else if (seedDistances->size() != queryFeatures->size()) {
    logger.err<<"ERROR: seedDistances should have come from matching a seed image to queryFeatures"<<"\n";
    exit(-1);
  } else {
    MemoryState seedOrigin = seedDistances->getMemoryState();
    if(seedOrigin != gpu) seedDistances->setMemoryState(gpu);
    matchFeaturesKDTree<T><<<grid, block>>>(queryID, queryFeatures->size(), queryFeatures->device.get(), 
    targetID, d_kdtree.get(), pd_nodes, d_points->device.get(), matches->device.get(), seedDistances->device.get(),
    this->relativeThreshold, this->absoluteThreshold);
    if(seedOrigin != gpu) seedDistances->setMemoryState(seedOrigin); 
  }
  cudaDeviceSynchronize();
  CudaCheckError();

  this->validateMatches(matches);
  printf("\n\ndone in %f seconds.\n\n",((float) clock() -  timer)/CLOCKS_PER_SEC);
  if(q_origin != gpu) queryFeatures->setMemoryState(q_origin);
  if(t_origin != gpu) kdtree.points->setMemoryState(t_origin);

  return matches;
} // generateDistanceMatches

template<typename T>
__global__ void ssrlcv::matchFeaturesKDTree(unsigned int queryImageID, unsigned long numFeaturesQuery, ssrlcv::Feature<T>* featuresQuery, unsigned int targetImageID, 
ssrlcv::KDTree<T>* kdtree, typename ssrlcv::KDTree<T>::Node* nodes, ssrlcv::Feature<T>* featuresTree, ssrlcv::DMatch* matches, float absoluteThreshold) {
  
  unsigned int globalThreadID = (blockIdx.y * gridDim.x + blockIdx.x) * blockDim.x + threadIdx.x; // 2D grid of 1D blocks
  
  if (globalThreadID < numFeaturesQuery) { 
    Feature<T> feature = featuresQuery[globalThreadID]; 
    __syncthreads();
    
    DMatch match;
    int emax = 100; // at most, search 100 leaf nodes
    match = findNearest(kdtree, nodes, featuresTree, feature, emax, absoluteThreshold); 
    __syncthreads();

    matches[globalThreadID] = match;
  } 

} // matchFeaturesKDTree

template<typename T>
__global__ void ssrlcv::matchFeaturesKDTree(unsigned int queryImageID, unsigned long numFeaturesQuery, ssrlcv::Feature<T>* featuresQuery, unsigned int targetImageID, 
ssrlcv::KDTree<T>* kdtree, typename ssrlcv::KDTree<T>::Node* nodes, ssrlcv::Feature<T>* featuresTree, ssrlcv::DMatch* matches, float* seedDistances, float relativeThreshold, float absoluteThreshold) {
  
  unsigned int globalThreadID = (blockIdx.y * gridDim.x + blockIdx.x) * blockDim.x + threadIdx.x; // 2D grid of 1D blocks
  
  if (globalThreadID < numFeaturesQuery) { 
    Feature<T> feature = featuresQuery[globalThreadID];
    float nearestSeed = seedDistances[globalThreadID];
    __syncthreads();
    
    DMatch match;
    int emax = 100; // at most, search 100 leaf nodes
    match = findNearest(kdtree, nodes, featuresTree, feature, emax, relativeThreshold, absoluteThreshold, nearestSeed); 
    __syncthreads();

    matches[globalThreadID] = match;
  } 

} // matchFeaturesKDTree

/*****************************************************
* SEED FEATURE STUFF THAT BELONGS IN MATCHFACTORY.CU *
******************************************************/

template<typename T>
ssrlcv::ptr::value<ssrlcv::Unity<float>> ssrlcv::MatchFactory<T>::getSeedDistances(ssrlcv::KDTree<T> kdtree) {

    // transfer query points to GPU
    MemoryState seed_origin = this->seedFeatures->getMemoryState();
    if(seed_origin != gpu) this->seedFeatures->setMemoryState(gpu);
        
    // transfer KD-Tree to GPU
    ssrlcv::ptr::device<ssrlcv::KDTree<T>> d_kdtree(1); 
    CudaSafeCall(cudaMemcpy(d_kdtree.get(),&kdtree,sizeof(kdtree),cudaMemcpyHostToDevice));
   
    // transfer KD-Tree nodes to GPU
    thrust::device_vector<typename KDTree<T>::Node> d_nodes = kdtree.nodes;
    typename KDTree<T>::Node* pd_nodes = thrust::raw_pointer_cast(d_nodes.data());

    // transfer KD-Tree points to GPU
    ssrlcv::ptr::value<ssrlcv::Unity<Feature<T>>> d_points = kdtree.points; 
    MemoryState t_origin = d_points->getMemoryState();
    if(t_origin != gpu) d_points->setMemoryState(gpu);
  
    // array to hold the matched pairs
    // unsigned int numPossibleMatches = features->size();
    unsigned int numPossibleMatches = kdtree.points->size(); 
    ssrlcv::ptr::value<ssrlcv::Unity<float>> matchDistances = ssrlcv::ptr::value<ssrlcv::Unity<float>>(nullptr, numPossibleMatches, gpu);
  
    // grid and block initilization
    dim3 grid = {1,1,1};
    dim3 block = {1,1,1};
    void (*ptr)(unsigned long, Feature<T>*, KDTree<T>*, typename KDTree<T>::Node*, Feature<T>*, float*) = &getSeedMatchDistances;
    getFlatGridBlock(kdtree.points->size(), grid, block, ptr);
    clock_t timer = clock();

    // call the kernel function getSeedMatchDistances
    getSeedMatchDistances<T><<<grid, block>>>(this->seedFeatures->size(), this->seedFeatures->device.get(), 
        d_kdtree.get(), pd_nodes, d_points->device.get(), matchDistances->device.get());
 
    cudaDeviceSynchronize();
    CudaCheckError();

    printf("seed match distances computed in %f seconds.\n\n",((float) clock() -  timer)/CLOCKS_PER_SEC);
    if(t_origin != gpu) kdtree.points->setMemoryState(t_origin);
    
    return matchDistances; 
} // getSeedDistances

template<typename T>
__global__ void ssrlcv::getSeedMatchDistances(unsigned long numSeedFeatures, Feature<T>* seedFeatures, ssrlcv::KDTree<T>* kdtree, 
typename ssrlcv::KDTree<T>::Node* nodes, ssrlcv::Feature<T>* featuresTree, float* matchDistances) {

    unsigned int globalThreadID = (blockIdx.y * gridDim.x + blockIdx.x) * blockDim.x + threadIdx.x; // 2D grid of 1D blocks 
    float dist = 0.0f;

    if (globalThreadID < numSeedFeatures) { 
      Feature<T> feature = seedFeatures[globalThreadID];
      __syncthreads();

      int emax = 100; // at most, search 100 leaf nodes
      dist = findNearest(kdtree, nodes, featuresTree, feature, emax); 
      __syncthreads();
    }  
    matchDistances[globalThreadID] = dist;
    // printf("\nmatchDistances[%i] = %f\n", globalThreadID, matchDistances[globalThreadID]);

} // getSeedMatchDistances

/* ************************************************************************************************************************************************************************************************************************************************************************** */

/****************
* DEBUG METHODS *
*****************/

template<typename T>
const float2 ssrlcv::KDTree<T>::getPoint(int ptidx, int *label) const {
    if ( !((unsigned)ptidx < (unsigned)points->size()) ) {
        logger.err<<"ERROR: point index is out of range"<<"\n";
    } 
    if (label) { *label = labels[ptidx]; }
    return points->host[ptidx].loc;
} // getPoint

template<typename T>
void ssrlcv::KDTree<T>::printKDTree() {
    printf("\nPRINTING KD TREE...\n\n");
    
    printf("NODES: \n\n");
    vector<Node> nodes = this->nodes;
    for (size_t i = 0; i < nodes.size(); i ++) {
        printf("Node %zu\n", i);
        printf("\tIndex: %d\n", nodes[i].idx);
        printf("\tIndex of Left Branch: %d\n", nodes[i].left);
        printf("\tIndex of Right Branch: %d\n", nodes[i].right);
    }
    printf("\n");

    printf("POINTS: \n\n");
    ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<T>>> points = this->points;
    for (size_t i = 0; i < points->size(); i++) {
        points->host[i].descriptor.print(); 
    }
    printf("\n");

    printf("LABELS: \n\n");
    thrust::host_vector<int> labels = this->labels;
    for (size_t i = 0; i < labels.size(); i++) {
        printf("%d\n", labels[i]);
    }
    printf("\n");
    
    printf("...DONE PRINTING\n\n");
} // printKDTree

ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>> generateFeatures() {

    ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>> features = ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>>(nullptr,N,ssrlcv::cpu); 
    ssrlcv::Feature<ssrlcv::SIFT_Descriptor>* featureptr = features->host.get();

    for (int i = 0; i < N; i++) {
        featureptr[i].loc = {(float)i, -1.0f}; 
        // fill descriptor with 128 random nums
        for (int j = 0; j < K; j++) {
            unsigned char r = (unsigned char) rand()/10;
            featureptr[i].descriptor.values[j] = r;
        }
        featureptr[i].descriptor.theta = 0.0f;
        featureptr[i].descriptor.sigma = 0.0f;
    } // for

    return features;
} // generatePoints

/**************
* MAIN METHOD *
***************/

int main() {

    /******************************
    *      VARIABLES TO TUNE      *
    *                             *
    * absoluteThreshold = 15000.0 *
    * reativeThreshold = 0.6      *
    * emax = 100                  *
    *******************************/

    ssrlcv::MatchFactory<ssrlcv::SIFT_Descriptor> matchFactory = ssrlcv::MatchFactory<ssrlcv::SIFT_Descriptor>(0.6f,15000.0f);

    // generate image features
    std::vector<ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>>> allFeatures;
    ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>> img1 = generateFeatures(); 
    ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>> img2 = generateFeatures(); 
    allFeatures.push_back(img1);
    allFeatures.push_back(img2);

    // generate seed features
    ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::Feature<ssrlcv::SIFT_Descriptor>>> seedFeatures = generateFeatures();
    
    // set seed features
    if (seedFeatures != nullptr)
      matchFactory.setSeedFeatures(seedFeatures);

    // print descriptors
    // printf("\nIMAGE 1 DESCRIPTORS\n");
    // for (size_t i = 0; i < img1->size(); i++) {
    //     cout << "(x, y) = " << "(" << img1->host[i].loc.x << ", " << img1->host[i].loc.y << ")" << endl;
    //     img1->host[i].descriptor.print();  
    //} 
    // printf("\nIMAGE 2 DESCRIPTORS\n");
    // for (size_t i = 0; i < img2->size(); i++) {
    //     cout << "(x, y) = " << "(" << img1->host[i].loc.x << ", " << img1->host[i].loc.y << ")" << endl;
    //     img2->host[i].descriptor.print(); 
    // }
    // printf("\nSEED FEATURE DESCRIPTORS\n");
    // for (size_t i = 0; i < seedFeatures->size(); i++) {
    //     cout << "(x, y) = " << "(" << seedFeatures->host[i].loc.x << ", " << seedFeatures->host[i].loc.y << ")" << endl;
    //     seedFeatures->host[i].descriptor.print(); 
    // }

    // build a kd tree using img1
    ssrlcv::KDTree<ssrlcv::SIFT_Descriptor> kdtree = ssrlcv::KDTree<ssrlcv::SIFT_Descriptor>(allFeatures[0]);

    // calculate distances from seed image to img1
    ssrlcv::ptr::value<ssrlcv::Unity<float>> seedDistances = (seedFeatures != nullptr) ? matchFactory.getSeedDistances(allFeatures[0]) : nullptr;
    seedDistances->transferMemoryTo(ssrlcv::cpu);
    
    // printf("\nIMAGE 1 DESCRIPTORS\n");
    // for (size_t i = 0; i < img1->size(); i++) {
    //     cout << "(x, y) = " << "(" << img1->host[i].loc.x << ", " << img1->host[i].loc.y << ")" << endl;
    //     img1->host[i].descriptor.print();  
    //} 

    // printf("\nSEED DISTANCES\n");
    // for (int i = 0; i < seedDistances->size(); i++) {
    //     printf("\nseedDistances[%i] = %f\n", i, seedDistances->host.get()[i]);
    // }

    // generate matches
    ssrlcv::ptr::value<ssrlcv::Unity<ssrlcv::DMatch>> dmatches = matchFactory.generateDistanceMatches(1,allFeatures[1],0,kdtree,seedDistances);
    dmatches->transferMemoryTo(ssrlcv::cpu);
    printf("\nDONE MATCHING\n");

    for (int i = 0; i < dmatches->size(); i++) { 
        printf("\nBEST MATCH\n");
        printf("\tdist = %f\n", dmatches->host[i].distance);
        printf("\tlocation of point on img1 = {%f, %f}\n", dmatches->host[i].keyPoints[0].loc.x, dmatches->host[i].keyPoints[0].loc.y); // kdtree
        printf("\tlocation of point on img2 = {%f, %f}\n", dmatches->host[i].keyPoints[1].loc.x, dmatches->host[i].keyPoints[1].loc.y); // query
    }

    const unsigned char *vec;
    const unsigned char *row;
    for (int i = 0; i < N; i++) { 
        vec = img1->host[i].descriptor.values;

        for (int j = 0; j < N; j ++) {
            row = img2->host[j].descriptor.values;
            float d = 0.f; // reset d
            int k = 0;
            for (k = 0, d = 0.f; k < K; k++) {
                float t = vec[k] - row[k];
                d += t*t;
            }
            cout << "DISTANCE BETWEEN img1[" << i << "] and img2[" << j << "] = " << d << endl; 
        } 
    } 

    return 0;
} // main