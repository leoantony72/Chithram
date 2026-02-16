now that i downloaded the models anf placed it in the model folder also the backend it set.


now the next thing to do is to integrate this with flutter app. THE client gets the model and then runs it in the device. ensure that the running doesn't make the phone laggy.

this face detection model runs yolov8n... which produce the results which should be stored in a local database. then each face should be alignment must be done. after which a unique embedding must be produced for this we use MobileFaceNet model. 

once all the processing is done, clustering is triggered. 

store whatever things are necessary for the future. also make sure that it fits perfectly to the current flutter ui of people faces.


it should also ensure that the image in the people page for individual ui must be replaced with the one of the images in the each cluster