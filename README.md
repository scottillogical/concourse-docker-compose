# concourse-docker-compose
This project is an example pipeline and docker image that allows you to use docker-compose to run integration tests in concourse

Note that this example shows how to fetch docker image dependencies and preload them into the docker daemon running in your concourse task. This utilizes built in concourse caching mechanisms to avoid having to download the docker images every time.


```yaml
resources:
- name: mongo-image
  source:
    repository: public.ecr.aws/docker/library/mongo
    tag: 5.0.21
  type: docker-image
- name: redis-image
  source:
    repository: public.ecr.aws/docker/library/redis
    tag: 5.0.11
  type: docker-image
- name: rabbitmq-image
  source:
    repository: public.ecr.aws/docker/library/rabbitmq
    tag: 3.8-management
  type: docker-image

jobs:
- get: jre-image
  params: {save: true}
- get: redis-image
  params: {save: true}
- get: mongo-image
  params: {save: true}
- get: rabbitmq-image
  params: {save: true}
- task: integration-tests
  privileged: true
  config:
    platform: linux
    image_resource:
      type: docker-image
      source:
        repository: <docker-registry-url>/concourse-dind
    inputs:
    - name: app
    - name: postgis-image
    - name: redis-image
    - name: mongo-image
    - name: runtime-tools-image
    - name: jre-image
    run:
      path: concourse-dind-entrypoint.sh
      args:
        - 'bash'
        - '-ec'
        - |
          set -x
          export DOCKER_BUILDKIT=1
          ls *image/image | xargs --no-run-if-empty -P 6 -n 1 docker load -i
          for imageToLoad in `ls -d *image`; do
            docker tag "$(cat ${imageToLoad}/image-id)" "$(cat ${imageToLoad}/repository):$(cat ${imageToLoad}/tag)"
          done
          cd cheetah
          cat docker-compose.yml
          docker-compose run test
```
