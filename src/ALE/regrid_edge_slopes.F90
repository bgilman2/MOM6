!> Routines that estimate edge slopes to be used in
!! high-order reconstruction schemes.
module regrid_edge_slopes

! This file is part of MOM6. See LICENSE.md for the license.

use regrid_solvers, only : solve_linear_system, solve_tridiagonal_system
use polynomial_functions, only : evaluation_polynomial

implicit none ; private

public edge_slopes_implicit_h3
public edge_slopes_implicit_h5

! Specifying a dimensional parameter value, as is done here, is a terrible idea.
real, parameter :: hNeglect_dflt = 1.E-30 !< Default negligible cell thickness

contains

!------------------------------------------------------------------------------
!> Compute ih4 edge slopes (implicit third order accurate)
!! in the same units as h.
!!
!! Compute edge slopes based on third-order implicit estimates. Note that
!! the estimates are fourth-order accurate on uniform grids
!!
!! Third-order implicit estimates of edge slopes are based on a two-cell
!! stencil. A tridiagonal system is set up and is based on expressing the
!! edge slopes in terms of neighboring cell averages. The generic
!! relationship is
!!
!! \f[
!! \alpha u'_{i-1/2} + u'_{i+1/2} + \beta u'_{i+3/2} =
!! a \bar{u}_i + b \bar{u}_{i+1}
!! \f]
!!
!! and the stencil looks like this
!!
!!          i     i+1
!!   ..--o------o------o--..
!!     i-1/2  i+1/2  i+3/2
!!
!! In this routine, the coefficients \f$\alpha\f$, \f$\beta\f$, a and b are computed,
!! the tridiagonal system is built, boundary conditions are prescribed and
!! the system is solved to yield edge-slope estimates.
!!
!! There are N+1 unknowns and we are able to write N-1 equations. The
!! boundary conditions close the system.
subroutine edge_slopes_implicit_h3( N, h, u, edge_slopes, h_neglect, answers_2018 )
  integer,              intent(in)    :: N !< Number of cells
  real, dimension(:),   intent(in)    :: h !< cell widths (size N) [H]
  real, dimension(:),   intent(in)    :: u !< cell average properties (size N) in arbitrary units [A]
  real, dimension(:,:), intent(inout) :: edge_slopes !< Returned edge slopes [A H-1]
  real, optional,       intent(in)    :: h_neglect !< A negligibly small width
  logical,    optional, intent(in)    :: answers_2018 !< If true use older, less acccurate expressions.
  ! Local variables
  integer               :: i, j                 ! loop indexes
  real                  :: h0, h1               ! cell widths [H]
  real                  :: h0_2, h1_2, h0h1     ! products of cell widths [H2]
  real                  :: h0_3, h1_3           ! products of three cell widths [H3]
  real                  :: d                    ! A demporary variable [H3]
  real                  :: alpha, beta          ! stencil coefficients [nondim]
  real                  :: a, b                 ! weights of cells [H-1]
  real, parameter       :: C1_12 = 1.0 / 12.0
  real, dimension(5)    :: x          ! Coordinate system with 0 at edges [H]
  real                  :: dx, xavg   ! Differences and averages of successive values of x [H]
  real, dimension(4,4)  :: Asys       ! matrix used to find boundary conditions
  real, dimension(4)    :: Bsys, Csys
  real, dimension(3)    :: Dsys
  real, dimension(N+1)  :: tri_l, &             ! trid. system (lower diagonal)  [nondim]
                           tri_d, &             ! trid. system (middle diagonal) [nondim]
                           tri_u, &             ! trid. system (upper diagonal)  [nondim]
                           tri_b, &             ! trid. system (unknowns vector) [A H-1]
                           tri_x                ! trid. system (rhs) [A H-1]
  real      :: hNeglect  ! A negligible thickness [H].
  real      :: hNeglect3 ! hNeglect^3 [H3].
  logical   :: use_2018_answers  ! If true use older, less acccurate expressions.

  hNeglect = hNeglect_dflt ; if (present(h_neglect))  hNeglect = h_neglect
  hNeglect3 = hNeglect**3
  use_2018_answers = .true. ; if (present(answers_2018)) use_2018_answers = answers_2018

  ! Loop on cells (except last one)
  do i = 1,N-1

    ! Get cell widths
    h0 = h(i)
    h1 = h(i+1)

    ! Auxiliary calculations
    h0h1 = h0 * h1
    h0_2 = h0 * h0
    h1_2 = h1 * h1
    h0_3 = h0_2 * h0
    h1_3 = h1_2 * h1

    d = 4.0 * h0h1 * ( h0 + h1 ) + h1_3 + h0_3

    ! Coefficients
    alpha = h1 * (h0_2 + h0h1 - h1_2) / ( d + hNeglect3 )
    beta  = h0 * (h1_2 + h0h1 - h0_2) / ( d + hNeglect3 )
    a = -12.0 * h0h1 / ( d + hNeglect3 )
    b = -a

    tri_l(i+1) = alpha
    tri_d(i+1) = 1.0
    tri_u(i+1) = beta

    tri_b(i+1) = a * u(i) + b * u(i+1)

  enddo ! end loop on cells

  ! Boundary conditions: left boundary
  x(1) = 0.0
  do i = 2,5
    x(i) = x(i-1) + h(i-1)
  enddo

  do i = 1,4
    dx = h(i)
    if (use_2018_answers) then
      do j = 1,4 ; Asys(i,j) = ( (x(i+1)**j) - (x(i)**j) ) / j ; enddo
    else  ! Use expressions with less sensitivity to roundoff
      xavg = 0.5 * (x(i+1) + x(i))
      Asys(i,1) = dx
      Asys(i,2) = dx * xavg
      Asys(i,3) = dx * (xavg**2 + C1_12*dx**2)
      Asys(i,4) = dx * xavg * (xavg**2 + 0.25*dx**2)
    endif

    Bsys(i) = u(i) * dx

  enddo

  call solve_linear_system( Asys, Bsys, Csys, 4 )

  Dsys(1) = Csys(2)
  Dsys(2) = 2.0 * Csys(3)
  Dsys(3) = 3.0 * Csys(4)

  tri_d(1) = 1.0
  tri_u(1) = 0.0
  tri_b(1) = evaluation_polynomial( Dsys, 3, x(1) )        ! first edge slope

  ! Boundary conditions: right boundary
  x(1) = 0.0
  do i = 2,5
    x(i) = x(i-1) + h(N-5+i)
  enddo

  do i = 1,4
    dx = h(N-4+i)
    if (use_2018_answers) then
      do j = 1,4 ; Asys(i,j) = ( (x(i+1)**j) - (x(i)**j) ) / j ; enddo
    else  ! Use expressions with less sensitivity to roundoff
      xavg = 0.5 * (x(i+1) + x(i))
      Asys(i,1) = dx
      Asys(i,2) = dx * xavg
      Asys(i,3) = dx * (xavg**2 + C1_12*dx**2)
      Asys(i,4) = dx * xavg * (xavg**2 + 0.25*dx**2)
    endif
    Bsys(i) = u(N-4+i) * dx

  enddo

  call solve_linear_system( Asys, Bsys, Csys, 4 )

  Dsys(1) = Csys(2)
  Dsys(2) = 2.0 * Csys(3)
  Dsys(3) = 3.0 * Csys(4)

  tri_l(N+1) = 0.0
  tri_d(N+1) = 1.0
  tri_b(N+1) = evaluation_polynomial( Dsys, 3, x(5) )      ! last edge slope

  ! Solve tridiagonal system and assign edge values
  call solve_tridiagonal_system( tri_l, tri_d, tri_u, tri_b, tri_x, N+1 )

  do i = 2,N
    edge_slopes(i,1)   = tri_x(i)
    edge_slopes(i-1,2) = tri_x(i)
  enddo
  edge_slopes(1,1) = tri_x(1)
  edge_slopes(N,2) = tri_x(N+1)

end subroutine edge_slopes_implicit_h3


!------------------------------------------------------------------------------
!> Compute ih5 edge values (implicit fifth order accurate)
subroutine edge_slopes_implicit_h5( N, h, u, edge_slopes, h_neglect, answers_2018 )
  integer,              intent(in)    :: N !< Number of cells
  real, dimension(:),   intent(in)    :: h !< cell widths (size N) [H]
  real, dimension(:),   intent(in)    :: u !< cell average properties (size N) in arbitrary units [A]
  real, dimension(:,:), intent(inout) :: edge_slopes !< Returned edge slopes [A H-1]
  real, optional,       intent(in)    :: h_neglect !< A negligibly small width [H]
  logical,    optional, intent(in)    :: answers_2018 !< If true use older, less acccurate expressions.
! -----------------------------------------------------------------------------
! Fifth-order implicit estimates of edge values are based on a four-cell,
! three-edge stencil. A tridiagonal system is set up and is based on
! expressing the edge slopes in terms of neighboring cell averages.
!
! The generic relationship is
!
! \alpha u'_{i-1/2} + u'_{i+1/2} + \beta u'_{i+3/2} =
! a \bar{u}_{i-1} + b \bar{u}_i + c \bar{u}_{i+1} + d \bar{u}_{i+2}
!
! and the stencil looks like this
!
!         i-1     i     i+1    i+2
!   ..--o------o------o------o------o--..
!            i-1/2  i+1/2  i+3/2
!
! In this routine, the coefficients \alpha, \beta, a, b, c and d are
! computed, the tridiagonal system is built, boundary conditions are
! prescribed and the system is solved to yield edge-value estimates.
!
! Note that the centered stencil only applies to edges 3 to N-1 (edges are
! numbered 1 to n+1), which yields N-3 equations for N+1 unknowns. Two other
! equations are written by using a right-biased stencil for edge 2 and a
! left-biased stencil for edge N. The prescription of boundary conditions
! (using sixth-order polynomials) closes the system.
!
! CAUTION: For each edge, in order to determine the coefficients of the
!          implicit expression, a 6x6 linear system is solved. This may
!          become computationally expensive if regridding is carried out
!          often. Figuring out closed-form expressions for these coefficients
!          on nonuniform meshes turned out to be intractable.
! -----------------------------------------------------------------------------

  ! Local variables
  integer               :: i, j, k              ! loop indexes
  real                  :: h0, h1, h2, h3       ! cell widths
  real                  :: g, g_2, g_3          ! the following are
  real                  :: g_4, g_5, g_6        ! auxiliary variables
  real                  :: d2, d3, d4, d5, d6   ! to set up the systems
  real                  :: n2, n3, n4, n5, n6   ! used to compute the
  real                  :: h1_2, h2_2           ! the coefficients of the
  real                  :: h1_3, h2_3           ! tridiagonal system
  real                  :: h1_4, h2_4           ! ...
  real                  :: h1_5, h2_5           ! ...
  real                  :: h1_6, h2_6           ! ...
  real                  :: h0ph1, h0ph1_2       ! ...
  real                  :: h0ph1_3, h0ph1_4     ! ...
  real                  :: h2ph3, h2ph3_2       ! ...
  real                  :: h2ph3_3, h2ph3_4     ! ...
  real                  :: alpha, beta          ! stencil coefficients
  real                  :: a, b, c, d           ! "
  real, dimension(7)    :: x                    ! Coordinate system with 0 at edges [same units as h]
  real, parameter       :: C1_12 = 1.0 / 12.0
  real, parameter       :: C5_6 = 5.0 / 6.0
  real                  :: dx, xavg             ! Differences and averages of successive values of x [same units as h]
  real, dimension(6,6)  :: Asys                 ! matrix used to find  boundary conditions
  real, dimension(6)    :: Bsys, Csys           ! ...
  real, dimension(5)    :: Dsys                 ! derivative
  real, dimension(N+1)  :: tri_l, &             ! trid. system (lower diagonal)
                           tri_d, &             ! trid. system (middle diagonal)
                           tri_u, &             ! trid. system (upper diagonal)
                           tri_b, &             ! trid. system (unknowns vector)
                           tri_x                ! trid. system (rhs)
  real      :: hNeglect ! A negligible thickness in the same units as h.
  logical   :: use_2018_answers ! If true use older, less acccurate expressions.

  hNeglect = hNeglect_dflt ; if (present(h_neglect)) hNeglect = h_neglect
  use_2018_answers = .true. ; if (present(answers_2018)) use_2018_answers = answers_2018

  ! Loop on cells (except last one)
  do k = 2,N-2

    ! Cell widths
    h0 = h(k-1)
    h1 = h(k+0)
    h2 = h(k+1)
    h3 = h(k+2)

    ! Auxiliary calculations
    h1_2 = h1 * h1
    h1_3 = h1_2 * h1
    h1_4 = h1_2 * h1_2
    h1_5 = h1_3 * h1_2
    h1_6 = h1_3 * h1_3

    h2_2 = h2 * h2
    h2_3 = h2_2 * h2
    h2_4 = h2_2 * h2_2
    h2_5 = h2_3 * h2_2
    h2_6 = h2_3 * h2_3

    g   = h0 + h1
    g_2 = g * g
    g_3 = g * g_2
    g_4 = g_2 * g_2
    g_5 = g_4 * g
    g_6 = g_3 * g_3

    d2 = ( h1_2 - g_2 ) / ( h0 + hNeglect )
    d3 = ( h1_3 - g_3 ) / ( h0 + hNeglect )
    d4 = ( h1_4 - g_4 ) / ( h0 + hNeglect )
    d5 = ( h1_5 - g_5 ) / ( h0 + hNeglect )
    d6 = ( h1_6 - g_6 ) / ( h0 + hNeglect )

    g   = h2 + h3
    g_2 = g * g
    g_3 = g * g_2
    g_4 = g_2 * g_2
    g_5 = g_4 * g
    g_6 = g_3 * g_3

    n2 = ( g_2 - h2_2 ) / ( h3 + hNeglect )
    n3 = ( g_3 - h2_3 ) / ( h3 + hNeglect )
    n4 = ( g_4 - h2_4 ) / ( h3 + hNeglect )
    n5 = ( g_5 - h2_5 ) / ( h3 + hNeglect )
    n6 = ( g_6 - h2_6 ) / ( h3 + hNeglect )

    ! Compute matrix entries
    Asys(1,1) = 0.0
    Asys(1,2) = 0.0
    Asys(1,3) = 1.0
    Asys(1,4) = 1.0
    Asys(1,5) = 1.0
    Asys(1,6) = 1.0

    Asys(2,1) = 1.0
    Asys(2,2) = 1.0
    Asys(2,3) = -0.5 * d2
    Asys(2,4) = 0.5 * h1
    Asys(2,5) = -0.5 * h2
    Asys(2,6) = -0.5 * n2

    Asys(3,1) = h1
    Asys(3,2) = - h2
    Asys(3,3) = - d3 / 6.0
    Asys(3,4) = h1_2 / 6.0
    Asys(3,5) = h2_2 / 6.0
    Asys(3,6) = n3 / 6.0

    Asys(4,1) = - h1_2 / 2.0
    Asys(4,2) = - h2_2 / 2.0
    Asys(4,3) = d4 / 24.0
    Asys(4,4) = - h1_3 / 24.0
    Asys(4,5) = h2_3 / 24.0
    Asys(4,6) = n4 / 24.0

    Asys(5,1) = h1_3 / 6.0
    Asys(5,2) = - h2_3 / 6.0
    Asys(5,3) = - d5 / 120.0
    Asys(5,4) = h1_4 / 120.0
    Asys(5,5) = h2_4 / 120.0
    Asys(5,6) = n5 / 120.0

    Asys(6,1) = - h1_4 / 24.0
    Asys(6,2) = - h2_4 / 24.0
    Asys(6,3) = d6 / 720.0
    Asys(6,4) = - h1_5 / 720.0
    Asys(6,5) = h2_5 / 720.0
    Asys(6,6) = n6 / 720.0

    Bsys(:) = (/ 0.0, -1.0, 0.0, 0.0, 0.0, 0.0 /)

    call solve_linear_system( Asys, Bsys, Csys, 6 )

    alpha = Csys(1)
    beta  = Csys(2)
    a = Csys(3)
    b = Csys(4)
    c = Csys(5)
    d = Csys(6)

    tri_l(k+1) = alpha
    tri_d(k+1) = 1.0
    tri_u(k+1) = beta
    tri_b(k+1) = a * u(k-1) + b * u(k) + c * u(k+1) + d * u(k+2)

  enddo ! end loop on cells

  ! Use a right-biased stencil for the second row

  ! Cell widths
  h0 = h(1)
  h1 = h(2)
  h2 = h(3)
  h3 = h(4)

  ! Auxiliary calculations
  h1_2 = h1 * h1
  h1_3 = h1_2 * h1
  h1_4 = h1_2 * h1_2
  h1_5 = h1_3 * h1_2
  h1_6 = h1_3 * h1_3

  h2_2 = h2 * h2
  h2_3 = h2_2 * h2
  h2_4 = h2_2 * h2_2
  h2_5 = h2_3 * h2_2
  h2_6 = h2_3 * h2_3

  g   = h0 + h1
  g_2 = g * g
  g_3 = g * g_2
  g_4 = g_2 * g_2
  g_5 = g_4 * g
  g_6 = g_3 * g_3

  h0ph1   = h0 + h1
  h0ph1_2 = h0ph1 * h0ph1
  h0ph1_3 = h0ph1_2 * h0ph1
  h0ph1_4 = h0ph1_2 * h0ph1_2

  d2 = ( h1_2 - g_2 ) / ( h0 + hNeglect )
  d3 = ( h1_3 - g_3 ) / ( h0 + hNeglect )
  d4 = ( h1_4 - g_4 ) / ( h0 + hNeglect )
  d5 = ( h1_5 - g_5 ) / ( h0 + hNeglect )
  d6 = ( h1_6 - g_6 ) / ( h0 + hNeglect )

  g   = h2 + h3
  g_2 = g * g
  g_3 = g * g_2
  g_4 = g_2 * g_2
  g_5 = g_4 * g
  g_6 = g_3 * g_3

  n2 = ( g_2 - h2_2 ) / ( h3 + hNeglect )
  n3 = ( g_3 - h2_3 ) / ( h3 + hNeglect )
  n4 = ( g_4 - h2_4 ) / ( h3 + hNeglect )
  n5 = ( g_5 - h2_5 ) / ( h3 + hNeglect )
  n6 = ( g_6 - h2_6 ) / ( h3 + hNeglect )

  ! Compute matrix entries
  Asys(1,1) = 0.0
  Asys(1,2) = 0.0
  Asys(1,3) = 1.0
  Asys(1,4) = 1.0
  Asys(1,5) = 1.0
  Asys(1,6) = 1.0

  Asys(2,1) = 1.0
  Asys(2,2) = 1.0
  Asys(2,3) = -0.5 * d2
  Asys(2,4) = 0.5 * h1
  Asys(2,5) = -0.5 * h2
  Asys(2,6) = -0.5 * n2

  Asys(3,1) = h0ph1
  Asys(3,2) = 0.0
  Asys(3,3) = - d3 / 6.0
  Asys(3,4) = h1_2 / 6.0
  Asys(3,5) = h2_2 / 6.0
  Asys(3,6) = n3 / 6.0

  Asys(4,1) = - h0ph1_2 / 2.0
  Asys(4,2) = 0.0
  Asys(4,3) = d4 / 24.0
  Asys(4,4) = - h1_3 / 24.0
  Asys(4,5) = h2_3 / 24.0
  Asys(4,6) = n4 / 24.0

  Asys(5,1) = h0ph1_3 / 6.0
  Asys(5,2) = 0.0
  Asys(5,3) = - d5 / 120.0
  Asys(5,4) = h1_4 / 120.0
  Asys(5,5) = h2_4 / 120.0
  Asys(5,6) = n5 / 120.0

  Asys(6,1) = - h0ph1_4 / 24.0
  Asys(6,2) = 0.0
  Asys(6,3) = d6 / 720.0
  Asys(6,4) = - h1_5 / 720.0
  Asys(6,5) = h2_5 / 720.0
  Asys(6,6) = n6 / 720.0

  Bsys(:) = (/ 0.0, -1.0, -h1, h1_2/2.0, -h1_3/6.0, h1_4/24.0 /)

  call solve_linear_system( Asys, Bsys, Csys, 6 )

  alpha = Csys(1)
  beta  = Csys(2)
  a = Csys(3)
  b = Csys(4)
  c = Csys(5)
  d = Csys(6)

  tri_l(2) = alpha
  tri_d(2) = 1.0
  tri_u(2) = beta
  tri_b(2) = a * u(1) + b * u(2) + c * u(3) + d * u(4)

  ! Boundary conditions: left boundary
  x(1) = 0.0
  do i = 2,7
    x(i) = x(i-1) + h(i-1)
  enddo

  do i = 1,6

    dx = h(i)
    if (use_2018_answers) then
      do j = 1,6 ; Asys(i,j) = ( (x(i+1)**j) - (x(i)**j) ) / j ; enddo
    else  ! Use expressions with less sensitivity to roundoff
      xavg = 0.5 * (x(i+1) + x(i))
      Asys(i,1) = dx
      Asys(i,2) = dx * xavg
      Asys(i,3) = dx * (xavg**2 + C1_12*dx**2)
      Asys(i,4) = dx * xavg * (xavg**2 + 0.25*dx**2)
      Asys(i,5) = dx * (xavg**4 + 0.5*xavg**2*dx**2 + 0.0125*dx**4)
      Asys(i,6) = dx * xavg * (xavg**4 + C5_6*xavg**2*dx**2 + 0.0625*dx**4)
    endif

    Bsys(i) = u(i) * dx

  enddo

  call solve_linear_system( Asys, Bsys, Csys, 6 )

  Dsys(1) = Csys(2)
  Dsys(2) = 2.0 * Csys(3)
  Dsys(3) = 3.0 * Csys(4)
  Dsys(4) = 4.0 * Csys(5)
  Dsys(5) = 5.0 * Csys(6)

  tri_d(1) = 0.0
  tri_d(1) = 1.0
  tri_u(1) = 0.0
  tri_b(1) = evaluation_polynomial( Dsys, 5, x(1) )        ! first edge value

  ! Use a left-biased stencil for the second to last row

  ! Cell widths
  h0 = h(N-3)
  h1 = h(N-2)
  h2 = h(N-1)
  h3 = h(N)

  ! Auxiliary calculations
  h1_2 = h1 * h1
  h1_3 = h1_2 * h1
  h1_4 = h1_2 * h1_2
  h1_5 = h1_3 * h1_2
  h1_6 = h1_3 * h1_3

  h2_2 = h2 * h2
  h2_3 = h2_2 * h2
  h2_4 = h2_2 * h2_2
  h2_5 = h2_3 * h2_2
  h2_6 = h2_3 * h2_3

  g   = h0 + h1
  g_2 = g * g
  g_3 = g * g_2
  g_4 = g_2 * g_2
  g_5 = g_4 * g
  g_6 = g_3 * g_3

  h2ph3   = h2 + h3
  h2ph3_2 = h2ph3 * h2ph3
  h2ph3_3 = h2ph3_2 * h2ph3
  h2ph3_4 = h2ph3_2 * h2ph3_2

  d2 = ( h1_2 - g_2 ) / ( h0 + hNeglect )
  d3 = ( h1_3 - g_3 ) / ( h0 + hNeglect )
  d4 = ( h1_4 - g_4 ) / ( h0 + hNeglect )
  d5 = ( h1_5 - g_5 ) / ( h0 + hNeglect )
  d6 = ( h1_6 - g_6 ) / ( h0 + hNeglect )

  g   = h2 + h3
  g_2 = g * g
  g_3 = g * g_2
  g_4 = g_2 * g_2
  g_5 = g_4 * g
  g_6 = g_3 * g_3

  n2 = ( g_2 - h2_2 ) / ( h3 + hNeglect )
  n3 = ( g_3 - h2_3 ) / ( h3 + hNeglect )
  n4 = ( g_4 - h2_4 ) / ( h3 + hNeglect )
  n5 = ( g_5 - h2_5 ) / ( h3 + hNeglect )
  n6 = ( g_6 - h2_6 ) / ( h3 + hNeglect )

  ! Compute matrix entries
  Asys(1,1) = 0.0
  Asys(1,2) = 0.0
  Asys(1,3) = 1.0
  Asys(1,4) = 1.0
  Asys(1,5) = 1.0
  Asys(1,6) = 1.0

  Asys(2,1) = 1.0
  Asys(2,2) = 1.0
  Asys(2,3) = -0.5 * d2
  Asys(2,4) = 0.5 * h1
  Asys(2,5) = -0.5 * h2
  Asys(2,6) = -0.5 * n2

  Asys(3,1) = 0.0
  Asys(3,2) = - h2ph3
  Asys(3,3) = - d3 / 6.0
  Asys(3,4) = h1_2 / 6.0
  Asys(3,5) = h2_2 / 6.0
  Asys(3,6) = n3 / 6.0

  Asys(4,1) = 0.0
  Asys(4,2) = - h2ph3_2 / 2.0
  Asys(4,3) = d4 / 24.0
  Asys(4,4) = - h1_3 / 24.0
  Asys(4,5) = h2_3 / 24.0
  Asys(4,6) = n4 / 24.0

  Asys(5,1) = 0.0
  Asys(5,2) = - h2ph3_3 / 6.0
  Asys(5,3) = - d5 / 120.0
  Asys(5,4) = h1_4 / 120.0
  Asys(5,5) = h2_4 / 120.0
  Asys(5,6) = n5 / 120.0

  Asys(6,1) = 0.0
  Asys(6,2) = - h2ph3_4 / 24.0
  Asys(6,3) = d6 / 720.0
  Asys(6,4) = - h1_5 / 720.0
  Asys(6,5) = h2_5 / 720.0
  Asys(6,6) = n6 / 720.0

  Bsys(:) = (/ 0.0, -1.0, h2, h2_2/2.0, h2_3/6.0, h2_4/24.0 /)

  call solve_linear_system( Asys, Bsys, Csys, 6 )

  alpha = Csys(1)
  beta  = Csys(2)
  a = Csys(3)
  b = Csys(4)
  c = Csys(5)
  d = Csys(6)

  tri_l(N) = alpha
  tri_d(N) = 1.0
  tri_u(N) = beta
  tri_b(N) = a * u(N-3) + b * u(N-2) + c * u(N-1) + d * u(N)

  ! Boundary conditions: right boundary
  x(1) = 0.0
  do i = 2,7
    x(i) = x(i-1) + h(N-7+i)
  enddo

  do i = 1,6
    dx = h(N-6+i)
    if (use_2018_answers) then
      do j = 1,6 ; Asys(i,j) = ( (x(i+1)**j) - (x(i)**j) ) / j ; enddo
    else  ! Use expressions with less sensitivity to roundoff
      xavg = 0.5 * (x(i+1) + x(i))
      Asys(i,1) = dx
      Asys(i,2) = dx * xavg
      Asys(i,3) = dx * (xavg**2 + C1_12*dx**2)
      Asys(i,4) = dx * xavg * (xavg**2 + 0.25*dx**2)
      Asys(i,5) = dx * (xavg**4 + 0.5*xavg**2*dx**2 + 0.0125*dx**4)
      Asys(i,6) = dx * xavg * (xavg**4 + C5_6*xavg**2*dx**2 + 0.0625*dx**4)
    endif
    Bsys(i) = u(N-6+i) * dx
  enddo

  call solve_linear_system( Asys, Bsys, Csys, 6 )

  Dsys(1) = Csys(2)
  Dsys(2) = 2.0 * Csys(3)
  Dsys(3) = 3.0 * Csys(4)
  Dsys(4) = 4.0 * Csys(5)
  Dsys(5) = 5.0 * Csys(6)

  tri_l(N+1) = 0.0
  tri_d(N+1) = 1.0
  tri_u(N+1) = 0.0
  tri_b(N+1) = evaluation_polynomial( Dsys, 5, x(7) )      ! last edge value

  ! Solve tridiagonal system and assign edge values
  call solve_tridiagonal_system( tri_l, tri_d, tri_u, tri_b, tri_x, N+1 )

  do i = 2,N
    edge_slopes(i,1)   = tri_x(i)
    edge_slopes(i-1,2) = tri_x(i)
  enddo
  edge_slopes(1,1) = tri_x(1)
  edge_slopes(N,2) = tri_x(N+1)

end subroutine edge_slopes_implicit_h5

end module regrid_edge_slopes
