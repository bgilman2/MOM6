!> Used to initialize tracers from a depth- (or z*-) space file.
module MOM_tracer_Z_init

! This file is part of MOM6. See LICENSE.md for the license.

!use MOM_diag_to_Z, only : find_overlap, find_limited_slope
use MOM_error_handler, only : MOM_error, FATAL, WARNING, MOM_mesg, is_root_pe
! use MOM_file_parser, only : get_param, log_version, param_file_type
use MOM_grid, only : ocean_grid_type
use MOM_io, only : MOM_read_data
use MOM_unit_scaling, only : unit_scale_type

use netcdf

implicit none ; private

#include <MOM_memory.h>

public tracer_Z_init

! A note on unit descriptions in comments: MOM6 uses units that can be rescaled for dimensional
! consistency testing. These are noted in comments with units like Z, H, L, and T, along with
! their mks counterparts with notation like "a velocity [Z T-1 ~> m s-1]".  If the units
! vary with the Boussinesq approximation, the Boussinesq variant is given first.

contains

!>   This function initializes a tracer by reading a Z-space file, returning
!! .true. if this appears to have been successful, and false otherwise.
function tracer_Z_init(tr, h, filename, tr_name, G, US, missing_val, land_val)
  logical :: tracer_Z_init !< A return code indicating if the initialization has been successful
  type(ocean_grid_type), intent(in)    :: G    !< The ocean's grid structure
  type(unit_scale_type), intent(in)    :: US !< A dimensional unit scaling type
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)), &
                         intent(out)   :: tr   !< The tracer to initialize
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)), &
                         intent(in)    :: h    !< Layer thicknesses [H ~> m or kg m-2]
  character(len=*),      intent(in)    :: filename !< The name of the file to read from
  character(len=*),      intent(in)    :: tr_name !< The name of the tracer in the file
! type(param_file_type), intent(in)    :: param_file !< A structure to parse for run-time parameters
  real,        optional, intent(in)    :: missing_val !< The missing value for the tracer
  real,        optional, intent(in)    :: land_val !< A value to use to fill in land points

  !   This function initializes a tracer by reading a Z-space file, returning true if this
  ! appears to have been successful, and false otherwise.
!
  integer, save :: init_calls = 0
! This include declares and sets the variable "version".
#include "version_variable.h"
  character(len=40)  :: mdl = "MOM_tracer_Z_init" ! This module's name.
  character(len=256) :: mesg    ! Message for error messages.

  real, allocatable, dimension(:,:,:) :: &
    tr_in   ! The z-space array of tracer concentrations that is read in.
  real, allocatable, dimension(:) :: &
    z_edges, &  ! The depths of the cell edges or cell centers (depending on
                ! the value of has_edges) in the input z* data [Z ~> m].
    tr_1d, &    ! A copy of the input tracer concentrations in a column.
    wt, &   ! The fractional weight for each layer in the range between
            ! k_top and k_bot, nondim.
    z1, &   ! z1 and z2 are the depths of the top and bottom limits of the part
    z2      ! of a z-cell that contributes to a layer, relative to the cell
            ! center and normalized by the cell thickness, nondim.
            ! Note that -1/2 <= z1 <= z2 <= 1/2.
  real    :: e(SZK_(G)+1)  ! The z-star interface heights [Z ~> m].
  real    :: landval    ! The tracer value to use in land points.
  real    :: sl_tr      ! The normalized slope of the tracer
                        ! within the cell, in tracer units.
  real    :: htot(SZI_(G)) ! The vertical sum of h [H ~> m or kg m-2].
  real    :: dilate     ! The amount by which the thicknesses are dilated to
                        ! create a z-star coordinate, nondim or in m3 kg-1.
  real    :: missing    ! The missing value for the tracer.

  logical :: has_edges, use_missing, zero_surface
  character(len=80) :: loc_msg
  integer :: k_top, k_bot, k_bot_prev
  integer :: i, j, k, kz, is, ie, js, je, nz, nz_in
  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke

  landval = 0.0 ; if (present(land_val)) landval = land_val

  zero_surface = .false. ! Make this false for errors to be fatal.

  use_missing = .false.
  if (present(missing_val)) then
    use_missing = .true. ; missing = missing_val
  endif

  ! Find out the number of input levels and read the depth of the edges,
  ! also modifying their sign convention to be monotonically decreasing.
  call read_Z_edges(filename, tr_name, z_edges, nz_in, has_edges, use_missing, &
                    missing, scale=US%m_to_Z)
  if (nz_in < 1) then
    tracer_Z_init = .false.
    return
  endif

  allocate(tr_in(G%isd:G%ied,G%jsd:G%jed,nz_in)) ; tr_in(:,:,:) = 0.0
  allocate(tr_1d(nz_in)) ; tr_1d(:) = 0.0
  call MOM_read_data(filename, tr_name, tr_in(:,:,:), G%Domain)

  ! Fill missing values from above?  Use a "close" test to avoid problems
  ! from type-conversion rounoff.
  if (present(missing_val)) then
    do j=js,je ; do i=is,ie
      if (G%mask2dT(i,j) == 0.0) then
        tr_in(i,j,1) = landval
      elseif (abs(tr_in(i,j,1) - missing_val) <= 1e-6*abs(missing_val)) then
        write(loc_msg,'(f7.2," N ",f7.2," E")') G%geoLatT(i,j), G%geoLonT(i,j)
        if (zero_surface) then
          call MOM_error(WARNING, "tracer_Z_init: Missing value of "// &
                trim(tr_name)//" found in an ocean point at "//trim(loc_msg)// &
                " in "//trim(filename) )
          tr_in(i,j,1) = 0.0
        else
          call MOM_error(FATAL, "tracer_Z_init: Missing value of "// &
                trim(tr_name)//" found in an ocean point at "//trim(loc_msg)// &
                " in "//trim(filename) )
        endif
      endif
    enddo ; enddo
    do k=2,nz_in ; do j=js,je ; do i=is,ie
      if (abs(tr_in(i,j,k) - missing_val) <= 1e-6*abs(missing_val)) &
        tr_in(i,j,k) = tr_in(i,j,k-1)
    enddo ; enddo ; enddo
  endif

  allocate(wt(nz_in+1)) ; allocate(z1(nz_in+1)) ; allocate(z2(nz_in+1))

  ! This is a placeholder, and will be replaced with our full vertical
  ! interpolation machinery when it is in place.
  if (has_edges) then
    do j=js,je
      do i=is,ie ; htot(i) = 0.0 ; enddo
      do k=1,nz ; do i=is,ie ; htot(i) = htot(i) + h(i,j,k) ; enddo ; enddo

      do i=is,ie ; if (G%mask2dT(i,j)*htot(i) > 0.0) then
        ! Determine the z* heights of the model interfaces.
        dilate = (G%bathyT(i,j) - 0.0) / htot(i)
        e(nz+1) = -G%bathyT(i,j)
        do k=nz,1,-1 ; e(K) = e(K+1) + dilate * h(i,j,k) ; enddo

        ! Create a single-column copy of tr_in.  ### CHANGE THIS LATER?
        do k=1,nz_in ; tr_1d(k) = tr_in(i,j,k) ; enddo
        k_bot = 1 ; k_bot_prev = -1
        do k=1,nz
          if (e(K+1) > z_edges(1)) then
            tr(i,j,k) = tr_1d(1)
          elseif (e(K) < z_edges(nz_in+1)) then
            tr(i,j,k) = tr_1d(nz_in)
          else
            call find_overlap(z_edges, e(K), e(K+1), nz_in, &
                              k_bot, k_top, k_bot, wt, z1, z2)
            kz = k_top
            if (kz /= k_bot_prev) then
              ! Calculate the intra-cell profile.
              sl_tr = 0.0 ! ; cur_tr = 0.0
              if ((kz < nz_in) .and. (kz > 1)) call &
                find_limited_slope(tr_1d, z_edges, sl_tr, kz)
            endif
            ! This is the piecewise linear form.
            tr(i,j,k) = wt(kz) * &
                (tr_1d(kz) + 0.5*sl_tr*(z2(kz) + z1(kz)))
            ! For the piecewise parabolic form add the following...
            !     + C1_3*cur_tr*(z2(kz)**2 + z2(kz)*z1(kz) + z1(kz)**2))
            do kz=k_top+1,k_bot-1
              tr(i,j,k) = tr(i,j,k) + wt(kz)*tr_1d(kz)
            enddo
            if (k_bot > k_top) then
              kz = k_bot
              ! Calculate the intra-cell profile.
              sl_tr = 0.0 ! ; cur_tr = 0.0
              if ((kz < nz_in) .and. (kz > 1)) call &
                find_limited_slope(tr_1d, z_edges, sl_tr, kz)
              ! This is the piecewise linear form.
              tr(i,j,k) = tr(i,j,k) + wt(kz) * &
                  (tr_1d(kz) + 0.5*sl_tr*(z2(kz) + z1(kz)))
              ! For the piecewise parabolic form add the following...
              !     + C1_3*cur_tr*(z2(kz)**2 + z2(kz)*z1(kz) + z1(kz)**2))
            endif
            k_bot_prev = k_bot

            !   Now handle the unlikely case where the layer partially extends
            ! past the valid range of the input data by extrapolating using
            ! the top or bottom value.
            if ((e(K) > z_edges(1)) .and. (z_edges(nz_in+1) > e(K+1))) then
              tr(i,j,k) = (((e(K) - z_edges(1)) * tr_1d(1) + &
                           (z_edges(1) - z_edges(nz_in)) * tr(i,j,k)) + &
                           (z_edges(nz_in+1) - e(K+1)) * tr_1d(nz_in)) / &
                          (e(K) - e(K+1))
            elseif (e(K) > z_edges(1)) then
              tr(i,j,k) = ((e(K) - z_edges(1)) * tr_1d(1) + &
                           (z_edges(1) - e(K+1)) * tr(i,j,k)) / &
                          (e(K) - e(K+1))
            elseif (z_edges(nz_in) > e(K+1)) then
              tr(i,j,k) = ((e(K) - z_edges(nz_in+1)) * tr(i,j,k) + &
                           (z_edges(nz_in+1) - e(K+1)) * tr_1d(nz_in)) / &
                          (e(K) - e(K+1))
            endif
          endif
        enddo ! k-loop
      else
        do k=1,nz ; tr(i,j,k) = landval ; enddo
      endif ; enddo ! i-loop
    enddo ! j-loop
  else
    ! Without edge values, integrate a linear interpolation between cell centers.
    do j=js,je
      do i=is,ie ; htot(i) = 0.0 ; enddo
      do k=1,nz ; do i=is,ie ; htot(i) = htot(i) + h(i,j,k) ; enddo ; enddo

      do i=is,ie ; if (G%mask2dT(i,j)*htot(i) > 0.0) then
        ! Determine the z* heights of the model interfaces.
        dilate = (G%bathyT(i,j) - 0.0) / htot(i)
        e(nz+1) = -G%bathyT(i,j)
        do k=nz,1,-1 ; e(K) = e(K+1) + dilate * h(i,j,k) ; enddo

        ! Create a single-column copy of tr_in.  ### CHANGE THIS LATER?
        do k=1,nz_in ; tr_1d(k) = tr_in(i,j,k) ; enddo
        k_bot = 1
        do k=1,nz
          if (e(K+1) > z_edges(1)) then
            tr(i,j,k) = tr_1d(1)
          elseif (z_edges(nz_in) > e(K)) then
            tr(i,j,k) = tr_1d(nz_in)
          else
            call find_overlap(z_edges, e(K), e(K+1), nz_in-1, &
                              k_bot, k_top, k_bot, wt, z1, z2)

            kz = k_top
            if (k_top < nz_in) then
              tr(i,j,k) = wt(kz)*0.5*((tr_1d(kz) + tr_1d(kz+1)) + &
                                      (tr_1d(kz+1) - tr_1d(kz))*(z2(kz)+z1(kz)))
            else
              tr(i,j,k) = wt(kz)*tr_1d(nz_in)
            endif
            do kz=k_top+1,k_bot-1
              tr(i,j,k) = tr(i,j,k) + wt(kz)*0.5*(tr_1d(kz) + tr_1d(kz+1))
            enddo
            if (k_bot > k_top) then
              kz = k_bot
              tr(i,j,k) = tr(i,j,k) + wt(kz)*0.5*((tr_1d(kz) + tr_1d(kz+1)) + &
                                        (tr_1d(kz+1) - tr_1d(kz))*(z2(kz)+z1(kz)))
            endif

            ! Now handle the case where the layer partially extends past
            ! the valid range of the input data.
            if ((e(K) > z_edges(1)) .and. (z_edges(nz_in) > e(K+1))) then
              tr(i,j,k) = (((e(K) - z_edges(1)) * tr_1d(1) + &
                           (z_edges(1) - z_edges(nz_in)) * tr(i,j,k)) + &
                           (z_edges(nz_in) - e(K+1)) * tr_1d(nz_in)) / &
                          (e(K) - e(K+1))
            elseif (e(K) > z_edges(1)) then
              tr(i,j,k) = ((e(K) - z_edges(1)) * tr_1d(1) + &
                           (z_edges(1) - e(K+1)) * tr(i,j,k)) / &
                          (e(K) - e(K+1))
            elseif (z_edges(nz_in) > e(K+1)) then
              tr(i,j,k) = ((e(K) - z_edges(nz_in)) * tr(i,j,k) + &
                           (z_edges(nz_in) - e(K+1)) * tr_1d(nz_in)) / &
                          (e(K) - e(K+1))
            endif
          endif
        enddo
      else
        do k=1,nz ; tr(i,j,k) = landval ; enddo
      endif ; enddo ! i-loop
    enddo  ! j-loop
  endif

  deallocate(tr_in) ; deallocate(tr_1d) ; deallocate(z_edges)
  deallocate(wt) ; deallocate(z1) ; deallocate(z2)

  tracer_Z_init = .true.

end function tracer_Z_init

!> This subroutine reads the vertical coordinate data for a field from a NetCDF file.
!! It also might read the missing value attribute for that same field.
subroutine read_Z_edges(filename, tr_name, z_edges, nz_out, has_edges, &
                        use_missing, missing, scale)
  character(len=*), intent(in)    :: filename !< The name of the file to read from.
  character(len=*), intent(in)    :: tr_name !< The name of the tracer in the file.
  real, dimension(:), allocatable, &
                    intent(out)   :: z_edges !< The depths of the vertical edges of the tracer array
  integer,          intent(out)   :: nz_out  !< The number of vertical layers in the tracer array
  logical,          intent(out)   :: has_edges !< If true the values in z_edges are the edges of the
                                             !! tracer cells, otherwise they are the cell centers
  logical,          intent(inout) :: use_missing !< If false on input, see whether the tracer has a
                                             !! missing value, and if so return true
  real,             intent(inout) :: missing !< The missing value, if one has been found
  real,             intent(in)    :: scale   !< A scaling factor for z_edges into new units.

  !   This subroutine reads the vertical coordinate data for a field from a
  ! NetCDF file.  It also might read the missing value attribute for that same field.
  character(len=32) :: mdl
  character(len=120) :: dim_name, edge_name, tr_msg, dim_msg
  logical :: monotonic
  integer :: ncid, status, intid, tr_id, layid, k
  integer :: nz_edge, ndim, tr_dim_ids(NF90_MAX_VAR_DIMS)

  mdl = "MOM_tracer_Z_init read_Z_edges: "
  tr_msg = trim(tr_name)//" in "//trim(filename)

  status = NF90_OPEN(filename, NF90_NOWRITE, ncid)
  if (status /= NF90_NOERR) then
    call MOM_error(WARNING,mdl//" Difficulties opening "//trim(filename)//&
        " - "//trim(NF90_STRERROR(status)))
    nz_out = -1 ; return
  endif

  status = NF90_INQ_VARID(ncid, tr_name, tr_id)
  if (status /= NF90_NOERR) then
    call MOM_error(WARNING,mdl//" Difficulties finding variable "//&
        trim(tr_msg)//" - "//trim(NF90_STRERROR(status)))
    nz_out = -1 ; status = NF90_CLOSE(ncid) ; return
  endif
  status = NF90_INQUIRE_VARIABLE(ncid, tr_id, ndims=ndim, dimids=tr_dim_ids)
  if (status /= NF90_NOERR) then
    call MOM_ERROR(WARNING,mdl//" cannot inquire about "//trim(tr_msg))
  elseif ((ndim < 3) .or. (ndim > 4)) then
    call MOM_ERROR(WARNING,mdl//" "//trim(tr_msg)//&
         " has too many or too few dimensions.")
    nz_out = -1 ; status = NF90_CLOSE(ncid) ; return
  endif

  if (.not.use_missing) then
    ! Try to find the missing value from the dataset.
    status = NF90_GET_ATT(ncid, tr_id, "missing_value", missing)
    if (status /= NF90_NOERR) use_missing = .true.
  endif

  ! Get the axis name and length.
  status = NF90_INQUIRE_DIMENSION(ncid, tr_dim_ids(3), dim_name, len=nz_out)
  if (status /= NF90_NOERR) then
    call MOM_ERROR(WARNING,mdl//" cannot inquire about dimension(3) of "//&
                    trim(tr_msg))
  endif

  dim_msg = trim(dim_name)//" in "//trim(filename)
  status = NF90_INQ_VARID(ncid, dim_name, layid)
  if (status /= NF90_NOERR) then
    call MOM_error(WARNING,mdl//" Difficulties finding variable "//&
        trim(dim_msg)//" - "//trim(NF90_STRERROR(status)))
    nz_out = -1 ; status = NF90_CLOSE(ncid) ; return
  endif
  ! Find out if the Z-axis has an edges attribute
  status = NF90_GET_ATT(ncid, layid, "edges", edge_name)
  if (status /= NF90_NOERR) then
    call MOM_mesg(mdl//" "//trim(dim_msg)//&
         " has no readable edges attribute - "//trim(NF90_STRERROR(status)))
    has_edges = .false.
  else
    has_edges = .true.
    status = NF90_INQ_VARID(ncid, edge_name, intid)
    if (status /= NF90_NOERR) then
      call MOM_error(WARNING,mdl//" Difficulties finding edge variable "//&
          trim(edge_name)//" in "//trim(filename)//" - "//trim(NF90_STRERROR(status)))
      has_edges = .false.
    endif
  endif

  nz_edge = nz_out ; if (has_edges) nz_edge = nz_out+1
  allocate(z_edges(nz_edge)) ; z_edges(:) = 0.0

  if (nz_out < 1) return

  ! Read the right variable.
  if (has_edges) then
    dim_msg = trim(edge_name)//" in "//trim(filename)
    status = NF90_GET_VAR(ncid, intid, z_edges)
    if (status /= NF90_NOERR) then
      call MOM_error(WARNING,mdl//" Difficulties reading variable "//&
          trim(dim_msg)//" - "//trim(NF90_STRERROR(status)))
      nz_out = -1 ; status = NF90_CLOSE(ncid) ; return
    endif
  else
    status = NF90_GET_VAR(ncid, layid, z_edges)
    if (status /= NF90_NOERR) then
      call MOM_error(WARNING,mdl//" Difficulties reading variable "//&
          trim(dim_msg)//" - "//trim(NF90_STRERROR(status)))
      nz_out = -1 ; status = NF90_CLOSE(ncid) ; return
    endif
  endif

  status = NF90_CLOSE(ncid)
  if (status /= NF90_NOERR) call MOM_error(WARNING, mdl// &
    " Difficulties closing "//trim(filename)//" - "//trim(NF90_STRERROR(status)))

  ! z_edges should be montonically decreasing with our sign convention.
  ! Change the sign sign convention if it looks like z_edges is increasing.
  if (z_edges(1) < z_edges(2)) then
    do k=1,nz_edge ; z_edges(k) = -z_edges(k) ; enddo
  endif
  ! Check that z_edges is now monotonically decreasing.
  monotonic = .true.
  do k=2,nz_edge ; if (z_edges(k) >= z_edges(k-1)) monotonic = .false. ; enddo
  if (.not.monotonic) &
    call MOM_error(WARNING,mdl//" "//trim(dim_msg)//" is not monotonic.")

  if (scale /= 1.0) then ; do k=1,nz_edge ; z_edges(k) = scale*z_edges(k) ; enddo ; endif

end subroutine read_Z_edges

!### `find_overlap` and `find_limited_slope` were previously part of
!    MOM_diag_to_Z.F90, and are nearly identical to `find_overlap` in
!    `midas_vertmap.F90` with some slight differences.  We keep it here for
!    reproducibility, but the two should be merged at some point

!> Determines the layers bounded by interfaces e that overlap
!! with the depth range between Z_top and Z_bot, and the fractional weights
!! of each layer. It also calculates the normalized relative depths of the range
!! of each layer that overlaps that depth range.

! ### TODO: Merge with midas_vertmap.F90:find_overlap()
subroutine find_overlap(e, Z_top, Z_bot, k_max, k_start, k_top, k_bot, wt, z1, z2)
  real, dimension(:), intent(in)    :: e      !< Column interface heights, in arbitrary units.
  real,               intent(in)    :: Z_top  !< Top of range being mapped to, in the units of e.
  real,               intent(in)    :: Z_bot  !< Bottom of range being mapped to, in the units of e.
  integer,            intent(in)    :: k_max  !< Number of valid layers.
  integer,            intent(in)    :: k_start !< Layer at which to start searching.
  integer,            intent(inout) :: k_top  !< Indices of top layers that overlap with the depth
                                              !! range.
  integer,            intent(inout) :: k_bot  !< Indices of bottom layers that overlap with the
                                              !! depth range.
  real, dimension(:), intent(out)   :: wt     !< Relative weights of each layer from k_top to k_bot.
  real, dimension(:), intent(out)   :: z1     !< Depth of the top limits of the part of
       !! a layer that contributes to a depth level, relative to the cell center and normalized
       !! by the cell thickness [nondim].  Note that -1/2 <= z1 < z2 <= 1/2.
  real, dimension(:), intent(out)   :: z2     !< Depths of the bottom limit of the part of
       !! a layer that contributes to a depth level, relative to the cell center and normalized
       !! by the cell thickness [nondim].  Note that -1/2 <= z1 < z2 <= 1/2.
  ! Local variables
  real    :: Ih, e_c, tot_wt, I_totwt
  integer :: k

  do k=k_start,k_max ; if (e(K+1)<Z_top) exit ; enddo
  k_top = k
  if (k>k_max) return

  ! Determine the fractional weights of each layer.
  ! Note that by convention, e and Z_int decrease with increasing k.
  if (e(K+1)<=Z_bot) then
    wt(k) = 1.0 ; k_bot = k
    Ih = 0.0 ; if (e(K) /= e(K+1)) Ih = 1.0 / (e(K)-e(K+1))
    e_c = 0.5*(e(K)+e(K+1))
    z1(k) = (e_c - MIN(e(K),Z_top)) * Ih
    z2(k) = (e_c - Z_bot) * Ih
  else
    wt(k) = MIN(e(K),Z_top) - e(K+1) ; tot_wt = wt(k) ! These are always > 0.
    if (e(K) /= e(K+1)) then
      z1(k) = (0.5*(e(K)+e(K+1)) - MIN(e(K), Z_top)) / (e(K)-e(K+1))
    else ; z1(k) = -0.5 ; endif
    z2(k) = 0.5
    k_bot = k_max
    do k=k_top+1,k_max
      if (e(K+1)<=Z_bot) then
        k_bot = k
        wt(k) = e(K) - Z_bot ; z1(k) = -0.5
        if (e(K) /= e(K+1)) then
          z2(k) = (0.5*(e(K)+e(K+1)) - Z_bot) / (e(K)-e(K+1))
        else ; z2(k) = 0.5 ; endif
      else
        wt(k) = e(K) - e(K+1) ; z1(k) = -0.5 ; z2(k) = 0.5
      endif
      tot_wt = tot_wt + wt(k) ! wt(k) is always > 0.
      if (k>=k_bot) exit
    enddo

    I_totwt = 1.0 / tot_wt
    do k=k_top,k_bot ; wt(k) = I_totwt*wt(k) ; enddo
  endif

end subroutine find_overlap

!> This subroutine determines a limited slope for val to be advected with
!! a piecewise limited scheme.
! ### TODO: Merge with midas_vertmap.F90:find_limited_slope()
subroutine find_limited_slope(val, e, slope, k)
  real, dimension(:), intent(in)  :: val !< A column of values that are being interpolated.
  real, dimension(:), intent(in)  :: e   !< Column interface heights in arbitrary units
  real,               intent(out) :: slope !< Normalized slope in the intracell distribution of val.
  integer,            intent(in)  :: k   !< Layer whose slope is being determined.
  ! Local variables
  real :: d1, d2  ! Thicknesses in the units of e.

  d1 = 0.5*(e(K-1)-e(K+1)) ; d2 = 0.5*(e(K)-e(K+2))
  if (((val(k)-val(k-1)) * (val(k)-val(k+1)) >= 0.0) .or. (d1*d2 <= 0.0)) then
    slope = 0.0 ! ; curvature = 0.0
  else
    slope = (d1**2*(val(k+1) - val(k)) + d2**2*(val(k) - val(k-1))) * &
            ((e(K) - e(K+1)) / (d1*d2*(d1+d2)))
    ! slope = 0.5*(val(k+1) - val(k-1))
    ! This is S.J. Lin's form of the PLM limiter.
    slope = sign(1.0,slope) * min(abs(slope), &
        2.0*(max(val(k-1),val(k),val(k+1)) - val(k)), &
        2.0*(val(k) - min(val(k-1),val(k),val(k+1))))
    ! curvature = 0.0
  endif

end subroutine find_limited_slope


end module MOM_tracer_Z_init
